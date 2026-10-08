import Foundation
import Photos
import RotatorCore

struct ScanProgress: Sendable, Equatable {
    var total = 0
    /// Photos visited this run, including those skipped.
    var visited = 0
    /// Photos actually analysed this run.
    var analyzed = 0
    /// Already scanned and unchanged since, screenshots, uneditable, or excluded by settings.
    var skipped = 0
    var found = 0
    var startedAt = Date()

    var fraction: Double { total == 0 ? 0 : Double(visited) / Double(total) }

    var photosPerSecond: Double {
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed > 1 ? Double(analyzed) / elapsed : 0
    }

    /// Rough time left, assuming the not-yet-visited photos all need analysing.
    var estimatedSecondsRemaining: Double? {
        let rate = photosPerSecond
        return rate > 0 ? Double(total - visited) / rate : nil
    }
}

/// Walks the whole library, analysing photos in parallel and persisting results in batches.
///
/// Designed for very large libraries:
/// - assets are pulled lazily from a `PHFetchResult`, never all loaded at once;
/// - only `concurrency` photos are in flight at a time, each as a small thumbnail, so memory stays flat;
/// - results are written in batches, and photos already scanned and unchanged are skipped, so a scan can be
///   stopped at any point and resumed later.
struct ScanEngine {
    var settings: ScanSettings
    var analyzer: OrientationAnalyzer
    var store: ResultStore

    /// Runs until the library is exhausted or the task is cancelled. Progress is reported a few times per second.
    func run(onProgress: @escaping @MainActor (ScanProgress) -> Void) async throws {
        let fetch = PhotoLibrary.fetchAllPhotos()
        let alreadyScanned = try await store.scannedModificationDates()

        var progress = ScanProgress(total: fetch.count)
        var pending: [ScanRecord] = []
        var lastReport = Date.distantPast
        var index = 0
        let concurrency = max(1, settings.concurrency)

        // Returns the next asset that needs analysing, counting the ones skipped on the way.
        func nextAsset() -> PHAsset? {
            while index < fetch.count {
                let asset = fetch.object(at: index)
                index += 1
                if shouldSkip(asset, alreadyScanned: alreadyScanned) {
                    progress.visited += 1
                    progress.skipped += 1
                    continue
                }
                return asset
            }
            return nil
        }

        try await withThrowingTaskGroup(of: ScanRecord.self) { group in
            for _ in 0..<concurrency {
                guard let asset = nextAsset() else { break }
                group.addTask { await analyze(asset) }
            }
            while let record = try await group.next() {
                progress.visited += 1
                progress.analyzed += 1
                if record.status == .needsRotation { progress.found += 1 }
                pending.append(record)

                if pending.count >= 250 {
                    try await store.upsert(pending)
                    pending.removeAll(keepingCapacity: true)
                }
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    let snapshot = progress
                    await onProgress(snapshot)
                }
                if Task.isCancelled { break }
                if let asset = nextAsset() {
                    group.addTask { await analyze(asset) }
                }
            }
            // On cancellation, keep whatever finished: those results are valid and save a rescan.
            group.cancelAll()
            while let record = try? await group.next() { pending.append(record) }
        }
        try await store.upsert(pending)
        await onProgress(progress)
    }

    private func shouldSkip(_ asset: PHAsset, alreadyScanned: [String: Double]) -> Bool {
        if let scannedDate = alreadyScanned[asset.localIdentifier],
           abs(scannedDate - modificationDate(of: asset)) < 1 {
            return true
        }
        if settings.skipScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return true }
        if settings.skipEditedPhotos && asset.hasAdjustments { return true }
        if !asset.canPerform(.content) { return true }
        return false
    }

    private func modificationDate(of asset: PHAsset) -> Double {
        (asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0
    }

    /// Fetches the thumbnail and runs Vision on a GCD worker thread: both calls block, and blocking the Swift
    /// concurrency pool with them would starve the actor that writes results.
    private func analyze(_ asset: PHAsset) async -> ScanRecord {
        let settings = settings
        let analyzer = analyzer
        let modDate = modificationDate(of: asset)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let record: ScanRecord = autoreleasepool {
                    var record = ScanRecord(
                        localIdentifier: asset.localIdentifier, modificationDate: modDate,
                        status: .unavailable, rotation: .none, confidence: 0, evidence: ""
                    )
                    guard let image = PhotoLibrary.analysisImage(
                        for: asset, longEdge: settings.analysisSize, allowNetwork: settings.allowNetworkForAnalysis
                    ) else { return record }
                    do {
                        let result = try analyzer.analyze(image)
                        record.status = result.decision.status
                        record.rotation = result.decision.rotation
                        record.confidence = result.decision.confidence
                        record.evidence = result.summary
                    } catch {
                        record.status = .failed
                        record.evidence = error.localizedDescription
                    }
                    return record
                }
                continuation.resume(returning: record)
            }
        }
    }
}
