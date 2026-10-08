import ImageIO
import RotatorCore

extension Rotation {
    /// The EXIF orientation whose display transform is this clockwise rotation.
    ///
    /// EXIF 6 (`.right`) is "rotate 90° CW to display", EXIF 8 (`.left`) is "rotate 270° CW", EXIF 3 (`.down`)
    /// is "rotate 180°". Vision's `VNImageRequestHandler(cgImage:orientation:)` and `CIImage.oriented(_:)` both
    /// use this mapping, so the transform the detector analysed is exactly the transform that gets applied.
    public var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .none: return .up
        case .clockwise90: return .right
        case .rotate180: return .down
        case .clockwise270: return .left
        }
    }
}

extension CGImagePropertyOrientation {
    public var isMirrored: Bool {
        switch self {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored: return true
        default: return false
        }
    }
}
