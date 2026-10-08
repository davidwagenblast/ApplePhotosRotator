import CoreImage
import Foundation
import ImageIO
import Photos
import RotatorCore
import UniformTypeIdentifiers

/// Applies rotations through PhotoKit's non-destructive editing API — the same mechanism Photos' own Rotate
/// command and third-party editing extensions use.
///
/// - The original file is never touched. Photos stores the rotated image as a new *edited version*, and
///   Image › Revert to Original in Photos restores the original at any time.
/// - Every asset-level property is preserved because the asset itself is not replaced: date, location, title,
///   caption, keywords, favourites, albums, people, and so on.
/// - The rendered version carries the original's embedded EXIF/TIFF/GPS/IPTC metadata, with only the orientation
///   and pixel dimensions updated to match the new pixels.
/// - All writes go through `PHPhotoLibrary.performChanges`, so the Photos database is updated by Photos itself;
///   this app never opens or modifies the library package on disk.
/// - Live Photos are edited with `PHLivePhotoEditingContext`, so they stay live.
struct RotationApplier {
    static let formatIdentifier = (Bundle.main.bundleIdentifier ?? "PhotoRotator") + ".rotation"
    static let formatVersion = "1"

    struct Item: Sendable {
        var localIdentifier: String
        var rotation: Rotation
        /// The asset's modification date when it was scanned; the edit is refused if the photo changed since.
        var scannedModificationDate: Double
    }

    struct Failure: Identifiable, Sendable {
        var id: String { localIdentifier }
        var localIdentifier: String
        var message: String
    }

    enum ApplyError: LocalizedError {
        case notFound, changedSinceScan, notEditable, noImageData, renderFailed(String), noRotation

        var errorDescription: String? {
            switch self {
            case .notFound: return "Photo no longer exists in the library."
            case .changedSinceScan: return "Photo was changed after it was scanned. Rescan, then review it again."
            case .notEditable: return "Photos does not allow this photo to be edited."
            case .noImageData: return "Photos could not provide the full-size image (is it still downloading from iCloud?)."
            case .renderFailed(let why): return "Could not render the rotated image: \(why)"
            case .noRotation: return "No rotation selected."
            }
        }
    }

    var store: ResultStore
    /// Photos edited and committed per `performChanges` call.
    var batchSize = 8
    /// Full-size renders in flight at once. Each can need several hundred MB for large photos.
    var renderConcurrency = 2

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Applies every item, committing in small batches. Returns the failures; everything else was applied.
    func apply(_ items: [Item], onProgress: @escaping @MainActor (_ done: Int, _ total: Int) -> Void) async -> [Failure] {
        var failures: [Failure] = []
        var done = 0
        for start in stride(from: 0, to: items.count, by: batchSize) {
            if Task.isCancelled { break }
            let batch = Array(items[start..<min(start + batchSize, items.count)])
            failures += await applyBatch(batch)
            done += batch.count
            await onProgress(done, items.count)
        }
        return failures
    }

    private func applyBatch(_ batch: [Item]) async -> [Failure] {
        let assets = PhotoLibrary.assets(withLocalIdentifiers: batch.map(\.localIdentifier))
        var failures: [Failure] = []
        var prepared: [(asset: PHAsset, output: PHContentEditingOutput)] = []

        // Render the batch, a couple of photos at a time.
        await withTaskGroup(of: (String, Result<(PHAsset, PHContentEditingOutput), Error>).self) { group in
            var iterator = batch.makeIterator()
            func addNext() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    do {
                        guard let asset = assets[item.localIdentifier] else { throw ApplyError.notFound }
                        return (item.localIdentifier, .success((asset, try await prepareEdit(asset: asset, item: item))))
                    } catch {
                        return (item.localIdentifier, .failure(error))
                    }
                }
            }
            for _ in 0..<renderConcurrency { addNext() }
            for await (id, result) in group {
                switch result {
                case .success(let edit): prepared.append(edit)
                case .failure(let error): failures.append(Failure(localIdentifier: id, message: error.localizedDescription))
                }
                addNext()
            }
        }

        guard !prepared.isEmpty else { return failures }
        do {
            try await commit(prepared)
        } catch {
            // One bad photo fails the whole transaction; retry individually so the rest still go through.
            for edit in prepared {
                do {
                    try await commit([edit])
                } catch {
                    failures.append(Failure(localIdentifier: edit.asset.localIdentifier, message: error.localizedDescription))
                }
            }
        }

        let failed = Set(failures.map(\.localIdentifier))
        let committed = prepared.map { $0.asset.localIdentifier }.filter { !failed.contains($0) }
        let refreshed = PhotoLibrary.assets(withLocalIdentifiers: committed)
        for id in committed {
            try? await store.markApplied(id, newModificationDate: refreshed[id]?.modificationDate?.timeIntervalSince1970)
        }
        return failures
    }

    private func commit(_ edits: [(asset: PHAsset, output: PHContentEditingOutput)]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for edit in edits {
                let request = PHAssetChangeRequest(for: edit.asset)
                request.contentEditingOutput = edit.output
            }
        }
    }

    // MARK: Rendering

    private func prepareEdit(asset: PHAsset, item: Item) async throws -> PHContentEditingOutput {
        guard item.rotation != .none else { throw ApplyError.noRotation }
        guard asset.canPerform(.content) else { throw ApplyError.notEditable }
        let current = (asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0
        guard abs(current - item.scannedModificationDate) < 1 else { throw ApplyError.changedSinceScan }

        let input = try await contentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        let adjustment = try JSONSerialization.data(withJSONObject: ["rotateClockwiseDegrees": item.rotation.degrees])
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: Self.formatIdentifier, formatVersion: Self.formatVersion, data: adjustment
        )

        if asset.mediaSubtypes.contains(.photoLive), let live = PHLivePhotoEditingContext(livePhotoEditingInput: input) {
            try await renderLivePhoto(live, rotation: item.rotation, to: output)
        } else {
            try await renderStill(input, rotation: item.rotation, to: output)
        }
        return output
    }

    /// Asks Photos for the image as currently displayed (any existing edits included), downloading the
    /// full-size version from iCloud if necessary.
    private func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // Never claim to understand another editor's adjustments. Photos then hands us its current rendered
        // version, so earlier edits (crops, filters, an earlier rotation) are kept in the result, and Revert to
        // Original still returns the untouched original.
        options.canHandleAdjustmentData = { _ in false }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? ApplyError.noImageData)
                }
            }
        }
    }

    private func renderStill(_ input: PHContentEditingInput, rotation: Rotation, to output: PHContentEditingOutput) async throws {
        guard let sourceURL = input.fullSizeImageURL else { throw ApplyError.noImageData }
        let orientation = input.fullSizeImageOrientation
        let context = Self.ciContext
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      let image = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: false])
                else { throw ApplyError.noImageData }
                let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

                // Bring the pixels to how Photos displays them, then apply the correction on top.
                var rotated = image.oriented(forExifOrientation: orientation).oriented(rotation.cgOrientation)
                rotated = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))

                let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                    ?? CGColorSpace(name: CGColorSpace.sRGB)!
                let deep = ((properties[kCGImagePropertyDepth] as? Int) ?? 8) > 8
                guard let cgImage = context.createCGImage(
                    rotated, from: rotated.extent, format: deep ? .RGBA16 : .RGBA8, colorSpace: colorSpace
                ) else { throw ApplyError.renderFailed("Core Image returned no image") }

                let type = output.defaultRenderedContentType ?? .jpeg
                let destinationURL = try output.renderedContentURL(for: type)
                guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type.identifier as CFString, 1, nil) else {
                    throw ApplyError.renderFailed("cannot write \(type.identifier)")
                }
                var metadata = Self.metadata(properties, width: cgImage.width, height: cgImage.height)
                metadata[kCGImageDestinationLossyCompressionQuality] = 0.95
                CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ApplyError.renderFailed("encoding failed") }
            }
        }.value
    }

    /// The source's metadata with orientation reset (the pixels are now upright) and dimensions updated.
    /// Everything else — capture date, camera, exposure, GPS, IPTC, colour profile name — is carried over.
    static func metadata(_ properties: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var metadata = properties
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyHasAlpha, kCGImagePropertyProfileName] {
            metadata.removeValue(forKey: key)
        }
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            // Subject-area coordinates refer to the old pixel grid.
            exif.removeValue(forKey: kCGImagePropertyExifSubjectArea)
            exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        return metadata
    }

    private func renderLivePhoto(_ context: PHLivePhotoEditingContext, rotation: Rotation, to output: PHContentEditingOutput) async throws {
        // Frames arrive in the stored pixel orientation and Photos re-applies `context.orientation` when it shows
        // the result. A pure rotation commutes with that, but a mirrored orientation reverses its direction.
        let pixelRotation = context.orientation.isMirrored ? rotation.inverse : rotation
        let cgOrientation = pixelRotation.cgOrientation
        context.frameProcessor = { frame, _ in
            let image = frame.image.oriented(cgOrientation)
            return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.saveLivePhoto(to: output, options: nil) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? ApplyError.renderFailed("Live Photo could not be saved"))
                }
            }
        }
    }
}
