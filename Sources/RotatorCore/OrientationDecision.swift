import Foundation

/// Evidence from one detector (faces, body pose, text, …).
///
/// The analyzer shows the detector the photo four times, once per candidate correction, and records how
/// strongly the photo looks upright after that correction. A value is in `0...1`, where 0 means "no upright
/// content found" and 1 means "certainly upright".
public struct DetectorEvidence: Sendable, Equatable {
    public var detector: String
    public var weight: Double
    public var uprightScores: [Rotation: Double]

    public init(detector: String, weight: Double, uprightScores: [Rotation: Double]) {
        self.detector = detector
        self.weight = weight
        self.uprightScores = uprightScores
    }

    public func score(for rotation: Rotation) -> Double {
        min(max(uprightScores[rotation] ?? 0, 0), 1)
    }
}

/// What the scan concluded about one photo.
public enum ScanStatus: Int, Sendable, Codable, CaseIterable {
    /// The photo already looks upright.
    case upright = 0
    /// The photo looks like it needs the proposed rotation.
    case needsRotation = 1
    /// Not enough evidence either way (for example, a landscape with no people or text).
    case inconclusive = 2
    /// No local image data (for example, iCloud-only with downloads disabled).
    case unavailable = 3
    /// Analysis failed.
    case failed = 4
}

public struct OrientationDecision: Sendable, Equatable {
    public var status: ScanStatus
    /// The best-supported correction (may be `.none`).
    public var rotation: Rotation
    /// How much the best correction beats the runner-up, scaled by how strong the evidence is; `0...1`.
    public var confidence: Double
    /// The combined, weighted score of the best correction.
    public var strength: Double

    public init(status: ScanStatus, rotation: Rotation, confidence: Double, strength: Double) {
        self.status = status
        self.rotation = rotation
        self.confidence = confidence
        self.strength = strength
    }
}

/// Fuses detector evidence into a single decision.
public struct OrientationDecider: Sendable {
    /// Below this combined score for the best candidate, the photo is `inconclusive`.
    public var minimumStrength: Double
    /// Below this confidence, a non-zero proposal is treated as `inconclusive` instead of `needsRotation`.
    /// The proposal is still reported so it can be stored and surfaced with a lower review threshold.
    public var minimumConfidence: Double

    public init(minimumStrength: Double = 0.3, minimumConfidence: Double = 0.2) {
        self.minimumStrength = minimumStrength
        self.minimumConfidence = minimumConfidence
    }

    public func decide(_ evidence: [DetectorEvidence]) -> OrientationDecision {
        var combined: [Rotation: Double] = [:]
        for rotation in Rotation.allCases {
            combined[rotation] = evidence.reduce(0) { $0 + $1.weight * $1.score(for: rotation) }
        }
        // Ties resolve toward `.none` so we never propose a change without a clear winner.
        let ranked = Rotation.allCases.sorted {
            let a = combined[$0]!, b = combined[$1]!
            return a != b ? a > b : $0.rawValue < $1.rawValue
        }
        let best = ranked[0]
        let bestScore = combined[best]!
        let secondScore = combined[ranked[1]]!

        guard bestScore >= minimumStrength else {
            return OrientationDecision(status: .inconclusive, rotation: .none, confidence: 0, strength: bestScore)
        }
        // Margin over the runner-up, normalised by the larger of the best score and 1 so weak evidence
        // (one blurry face) can't produce a high confidence just because everything else scored zero.
        let confidence = min(max((bestScore - secondScore) / max(bestScore, 1), 0), 1)

        if best == Rotation.none {
            return OrientationDecision(status: .upright, rotation: .none, confidence: confidence, strength: bestScore)
        }
        let status: ScanStatus = confidence >= minimumConfidence ? .needsRotation : .inconclusive
        return OrientationDecision(status: status, rotation: best, confidence: confidence, strength: bestScore)
    }
}

/// Combines independent probabilities: the chance that at least one piece of evidence is right.
public func noisyOr<S: Sequence>(_ probabilities: S) -> Double where S.Element == Double {
    1 - probabilities.reduce(1.0) { $0 * (1 - min(max($1, 0), 1)) }
}

/// How upright a feature is, given its angle (radians) away from vertical in the analysed frame.
/// Returns `cos(angle)` within `tolerance`, otherwise 0.
public func uprightFactor(angleFromVertical angle: Double, toleranceDegrees tolerance: Double) -> Double {
    var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if a > .pi { a -= 2 * .pi }
    if a < -.pi { a += 2 * .pi }
    guard abs(a) <= tolerance * .pi / 180 else { return 0 }
    return cos(a)
}
