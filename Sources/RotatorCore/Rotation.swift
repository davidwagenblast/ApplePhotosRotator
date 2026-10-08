/// A clockwise rotation, in multiples of 90°, that should be applied to a photo *as it is currently
/// displayed* to make it upright.
public enum Rotation: Int, CaseIterable, Codable, Sendable, Hashable {
    case none = 0
    case clockwise90 = 90
    case rotate180 = 180
    case clockwise270 = 270

    /// Creates a rotation from any angle in degrees (clockwise), snapping to the nearest multiple of 90°.
    public init(degrees: Int) {
        let snapped = ((Int((Double(degrees) / 90.0).rounded()) * 90) % 360 + 360) % 360
        self = Rotation(rawValue: snapped) ?? Rotation.none
    }

    public var degrees: Int { rawValue }

    /// The rotation that undoes this one.
    public var inverse: Rotation { Rotation(degrees: 360 - rawValue) }

    /// Applying `self` and then `other`.
    public func followed(by other: Rotation) -> Rotation {
        Rotation(degrees: rawValue + other.rawValue)
    }

    /// Whether this rotation swaps width and height.
    public var swapsDimensions: Bool { self == .clockwise90 || self == .clockwise270 }

    public var label: String {
        switch self {
        case .none: return "No rotation"
        case .clockwise90: return "Rotate 90° clockwise"
        case .rotate180: return "Rotate 180°"
        case .clockwise270: return "Rotate 90° counter-clockwise"
        }
    }

    public var shortLabel: String {
        switch self {
        case .none: return "0°"
        case .clockwise90: return "90° ↻"
        case .rotate180: return "180°"
        case .clockwise270: return "90° ↺"
        }
    }

    /// The three rotations that actually change a photo.
    public static let corrections: [Rotation] = [.clockwise90, .rotate180, .clockwise270]
}
