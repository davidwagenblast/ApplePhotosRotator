import AppKit
import Photos

/// Read-only access to the Photos library: authorization, fetching, and image requests.
/// Every change to the library goes through `RotationApplier`, using PhotoKit's edit API.
enum PhotoLibrary {
    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// All still photos in the user's own library (not shared albums, which cannot be edited), newest first.
    /// `PHFetchResult` loads objects lazily, so this is cheap even for hundreds of thousands of photos.
    static func fetchAllPhotos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    static func assets(withLocalIdentifiers ids: [String]) -> [String: PHAsset] {
        var result: [String: PHAsset] = [:]
        result.reserveCapacity(ids.count)
        // Chunked so a 20,000-item review list doesn't build one giant predicate.
        stride(from: 0, to: ids.count, by: 500).forEach { start in
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil).enumerateObjects { asset, _, _ in
                result[asset.localIdentifier] = asset
            }
        }
        return result
    }

    /// A small, display-oriented image for analysis. **Blocking** — call it from a background thread only.
    ///
    /// The image is what Photos shows (current edits and orientation applied), which is exactly what the user judges
    /// as "sideways", so proposals are relative to what they see.
    static func analysisImage(for asset: PHAsset, longEdge: Int, allowNetwork: Bool) -> CGImage? {
        let size = CGSize(width: longEdge, height: longEdge)
        for mode in [PHImageRequestOptionsDeliveryMode.highQualityFormat, .fastFormat] {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = mode
            options.resizeMode = .fast
            options.version = .current
            options.isNetworkAccessAllowed = allowNetwork
            var result: CGImage?
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
                result = image.flatMap { displayedPixels(of: $0, maxLongEdge: longEdge) }
            }
            if let result, result.width >= 64, result.height >= 64 { return result }
        }
        return nil
    }

    /// The image as it appears on screen, as an upright bitmap.
    ///
    /// Don't use `NSImage.cgImage(forProposedRect:context:hints:)` for this: it can hand back the stored pixels
    /// without the orientation that the image shows them with (a portrait iPhone photo is stored sideways, with a
    /// tag saying to turn it), so every such photo would be analysed sideways. Drawing applies whatever the image
    /// applies on screen.
    static func displayedPixels(of image: NSImage, maxLongEdge: Int) -> CGImage? {
        let displayed = image.size
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxLongEdge) / max(displayed.width, displayed.height))
        let width = max(1, Int((displayed.width * scale).rounded()))
        let height = max(1, Int((displayed.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Thumbnails for the review grid, cached in memory.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 600
    }

    func thumbnail(for asset: PHAsset, pixelSize: CGFloat) async -> NSImage? {
        let key = "\(asset.localIdentifier)|\(Int(pixelSize))|\(asset.modificationDate?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.version = .current

        let image: NSImage? = await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: pixelSize, height: pixelSize),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // .highQualityFormat calls back once, but guard anyway: resuming twice would crash.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded || image == nil else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
