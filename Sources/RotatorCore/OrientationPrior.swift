import Foundation

/// How common each correction is in a real photo library, before looking at the photo.
///
/// The orientation network was trained with all four turns equally likely, so its probabilities assume a quarter of
/// all photos are upside down. In a real library almost every photo is upright, sideways photos are occasional and
/// upside-down ones rare. Re-weighting by these odds (Bayes' rule) stops the network from proposing a rare turn
/// unless it is very sure.
public struct OrientationPrior: Sendable, Equatable {
    public var upright: Double
    /// For each sideways direction (90° and 270° separately).
    public var sideways: Double
    public var upsideDown: Double

    public init(upright: Double, sideways: Double, upsideDown: Double) {
        self.upright = upright
        self.sideways = sideways
        self.upsideDown = upsideDown
    }

    /// The odds the network was trained with.
    public static let equal = OrientationPrior(upright: 0.25, sideways: 0.25, upsideDown: 0.25)

    public func probability(of rotation: Rotation) -> Double {
        switch rotation {
        case .none: return upright
        case .clockwise90, .clockwise270: return sideways
        case .rotate180: return upsideDown
        }
    }

    /// Re-weights scores from a model trained with equal odds, keeping their total.
    public func apply(to scores: [Rotation: Double]) -> [Rotation: Double] {
        let total = scores.values.reduce(0, +)
        var weighted: [Rotation: Double] = [:]
        for rotation in Rotation.allCases {
            weighted[rotation] = (scores[rotation] ?? 0) * probability(of: rotation) / 0.25
        }
        let weightedTotal = weighted.values.reduce(0, +)
        guard weightedTotal > 0 else { return scores }
        return weighted.mapValues { $0 * total / weightedTotal }
    }
}
