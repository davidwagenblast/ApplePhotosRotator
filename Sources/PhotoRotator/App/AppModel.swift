import AppKit
import Foundation
import Observation
import Photos
import RotatorCore

struct ReviewItem: Identifiable {
    var id: String { asset.localIdentifier }
    var asset: PHAsset
    var proposed: Rotation
    var confidence: Double
    var evidence: String
    var scannedModificationDate: Double
}

@MainActor
@Observable
final class AppModel {
    enum Screen: Hashable { case scan, review }

    var authorization = PhotoLibrary.authorizationStatus
    var screen: Screen = .scan
    var errorMessage: String?

    var settings = ScanSettings.load() {
        didSet { settings.save() }
    }

    // MARK: Scan state
    var libraryCount = 0
    var counts = ScanCounts()
    var progress: ScanProgress?
    var isScanning = false
    private var scanTask: Task<Void, Never>?

    // MARK: Review state
    private(set) var reviewItems: [ReviewItem] = []
    private(set) var visibleItems: [ReviewItem] = []
    var selection: Set<String> = []
    /// Rotations the user changed by hand in review.
    var overrides: [String: Rotation] = [:]
    var minimumConfidence = 0.5 { didSet { refilter() } }
    var rotationFilter: Rotation? { didSet { refilter() } }
    var isLoadingReview = false

    // MARK: Apply state
    var applyProgress: (done: Int, total: Int)?
    var applyFailures: [RotationApplier.Failure] = []
    var isApplying = false
    var lastAppliedCount = 0
    private var applyTask: Task<Void, Never>?

    /// Whether the built-in orientation network loaded; `nil` until checked.
    var networkReady: Bool?

    var diagnosticsCopied = false

    // MARK: Undo state
    var isUndoing = false
    var undoMessage: String?

    private var store: ResultStore?

    init() {
        do {
            store = try ResultStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }

    func rotation(for item: ReviewItem) -> Rotation { overrides[item.id] ?? item.proposed }

    var selectedVisibleItems: [ReviewItem] { visibleItems.filter { selection.contains($0.id) } }

    // MARK: Lifecycle

    func requestAccess() async {
        authorization = await PhotoLibrary.requestAuthorization()
        if isAuthorized { await onAuthorized() }
    }

    func onAuthorized() async {
        if networkReady == nil {
            // Loading may compile the model the first time, so keep it off the main thread.
            networkReady = await Task.detached(priority: .userInitiated) { OrientationNetDetector.builtIn != nil }.value
        }
        libraryCount = PhotoLibrary.fetchAllPhotos().count
        await refreshCounts()
        await loadReview()
    }

    func refreshCounts() async {
        guard let store else { return }
        do { counts = try await store.counts() } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Scanning

    func startScan() {
        guard let store, !isScanning else { return }
        isScanning = true
        progress = ScanProgress()
        let settings = settings
        scanTask = Task {
            defer { isScanning = false }
            do {
                var model: CoreMLDetector?
                if let path = settings.modelPath, !path.isEmpty {
                    model = try await CoreMLDetector.load(from: URL(fileURLWithPath: path))
                }
                let engine = ScanEngine(
                    settings: settings,
                    analyzer: OrientationAnalyzer(settings: settings, model: model),
                    store: store
                )
                try await engine.run { progress in
                    self.progress = progress
                }
            } catch {
                errorMessage = "Scan stopped: \(error.localizedDescription)"
            }
            libraryCount = PhotoLibrary.fetchAllPhotos().count
            await refreshCounts()
            await loadReview()
        }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    func resetResults() async {
        guard let store, !isScanning else { return }
        do {
            try await store.reset()
        } catch {
            errorMessage = error.localizedDescription
        }
        progress = nil
        await refreshCounts()
        await loadReview()
    }

    // MARK: Review

    func loadReview() async {
        guard let store else { return }
        isLoadingReview = true
        defer { isLoadingReview = false }
        do {
            let records = try await store.pendingProposals()
            let assets = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.assets(withLocalIdentifiers: records.map(\.localIdentifier))
            }.value
            reviewItems = records.compactMap { record in
                guard let asset = assets[record.localIdentifier] else { return nil }
                // Drop proposals for photos edited since the scan: the proposal may no longer apply.
                let modified = (asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0
                guard abs(modified - record.modificationDate) < 1 else { return nil }
                return ReviewItem(
                    asset: asset, proposed: record.rotation, confidence: record.confidence,
                    evidence: record.evidence, scannedModificationDate: record.modificationDate
                )
            }
            overrides = overrides.filter { id, _ in assets[id] != nil }
            refilter()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refilter() {
        visibleItems = reviewItems.filter { item in
            item.confidence >= minimumConfidence && (rotationFilter == nil || rotation(for: item) == rotationFilter)
        }
        // Only what is on screen can be selected, so "Apply" never touches photos the user can't see.
        let visibleIDs = Set(visibleItems.map(\.id))
        selection.formIntersection(visibleIDs)
    }

    func setOverride(_ rotation: Rotation, for item: ReviewItem) {
        overrides[item.id] = rotation == item.proposed ? nil : rotation
        if rotationFilter != nil { refilter() }
    }

    func toggle(_ item: ReviewItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func selectAll() { selection = Set(visibleItems.map(\.id)) }
    func selectNone() { selection.removeAll() }

    /// "These are fine": hides the selected photos from review for good (until they change and are rescanned).
    func dismissSelected() async {
        guard let store else { return }
        let ids = Array(selection)
        do {
            try await store.dismiss(ids)
            let removed = Set(ids)
            reviewItems.removeAll { removed.contains($0.id) }
            selection.removeAll()
            refilter()
            await refreshCounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Applying

    func applySelected() {
        guard let store, !isApplying else { return }
        let items = selectedVisibleItems.map {
            RotationApplier.Item(
                localIdentifier: $0.id, rotation: rotation(for: $0), scannedModificationDate: $0.scannedModificationDate
            )
        }
        guard !items.isEmpty else { return }
        isApplying = true
        applyFailures = []
        applyProgress = (0, items.count)
        applyTask = Task {
            let failures = await RotationApplier(store: store).apply(items) { done, total in
                self.applyProgress = (done, total)
            }
            let failed = Set(failures.map(\.localIdentifier))
            let attempted = Set(items.prefix(applyProgress?.done ?? items.count).map(\.localIdentifier))
            let applied = attempted.subtracting(failed)
            lastAppliedCount = applied.count
            applyFailures = failures
            reviewItems.removeAll { applied.contains($0.id) }
            selection.subtract(applied)
            for id in applied { overrides[id] = nil }
            refilter()
            await refreshCounts()
            isApplying = false
        }
    }

    /// Returns every photo this app has rotated to its original, using Photos' Revert to Original, and forgets their
    /// scan results so the next scan checks them again.
    func undoAllRotations() async {
        guard let store, !isUndoing, !isApplying else { return }
        isUndoing = true
        defer { isUndoing = false }
        do {
            let ids = try await store.appliedIdentifiers()
            let assets = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.assets(withLocalIdentifiers: ids)
            }.value
            var reverted: [String] = []
            var failed = 0
            let editable = ids.compactMap { assets[$0] }.filter { $0.canPerform(.content) }
            for start in stride(from: 0, to: editable.count, by: 50) {
                let batch = Array(editable[start..<min(start + 50, editable.count)])
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for asset in batch { PHAssetChangeRequest(for: asset).revertAssetContentToOriginal() }
                    }
                    reverted += batch.map(\.localIdentifier)
                } catch {
                    // Retry one by one so a single problem photo doesn't block the rest.
                    for asset in batch {
                        do {
                            try await PHPhotoLibrary.shared().performChanges {
                                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
                            }
                            reverted.append(asset.localIdentifier)
                        } catch {
                            failed += 1
                        }
                    }
                }
            }
            // Photos that no longer exist have nothing to undo.
            let missing = ids.filter { assets[$0] == nil }
            try await store.forget(reverted + missing)
            undoMessage = failed == 0
                ? "Returned \(reverted.count.formatted()) photos to their originals."
                : "Returned \(reverted.count.formatted()) photos to their originals. \(failed.formatted()) could not be reverted; use Image › Revert to Original in Photos for those."
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshCounts()
    }

    /// Copies a plain-text report about the top proposals on screen (no photos, no names) for troubleshooting.
    func copyDiagnostics() async {
        let items = Array(visibleItems.prefix(30))
        let size = settings.analysisSize
        let header = [
            "Photo Rotator diagnostics",
            "analysis version \(ResultStore.analysisVersion); orientation network \(networkReady == true ? "ready" : "NOT loaded")",
            "settings: faces \(settings.useFaces), body \(settings.useBodyPose), scenes \(settings.useScene), text \(settings.useText), size \(size)",
            "results: \(counts.upright) upright, \(counts.needsRotation) need rotating, \(counts.inconclusive) unsure, \(counts.applied) rotated by the app",
            "showing \(visibleItems.count) proposals at ≥\(Int(minimumConfidence * 100))%; first \(items.count):",
        ]
        let lines = items.enumerated().map { index, item in
            "\(index + 1). \(item.proposed.shortLabel) \(Int((item.confidence * 100).rounded()))% [\(item.evidence)] · "
                + "\(item.asset.pixelWidth)×\(item.asset.pixelHeight)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((header + lines).joined(separator: "\n"), forType: .string)
        diagnosticsCopied = true
    }

    func cancelApply() {
        applyTask?.cancel()
    }

    func finishApply() {
        applyProgress = nil
        applyFailures = []
    }
}
