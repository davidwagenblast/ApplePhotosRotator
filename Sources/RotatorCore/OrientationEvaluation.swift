import Foundation

/// Scores held-out photos exactly the way the app judges them — four passes averaged, then `OrientationDecider` —
/// and tallies what a person reviewing the results would see at each minimum-confidence setting.
public struct OrientationEvaluation {
    public static let thresholds = [0.3, 0.5, 0.6, 0.7, 0.8]

    public var weight: Double
    public private(set) var uprightCases = 0
    public private(set) var rotatedCases = 0
    public private(set) var falseProposals: [Int]
    public private(set) var correctProposals: [Int]
    public private(set) var wrongDirection: [Int]
    private let decider = OrientationDecider()

    public init(weight: Double) {
        self.weight = weight
        falseProposals = Array(repeating: 0, count: Self.thresholds.count)
        correctProposals = falseProposals
        wrongDirection = falseProposals
    }

    /// Adds one upright photo, tested in all four orientations. `probabilities[m]` are the model's four class
    /// probabilities for the photo turned so that it needs `m` quarter turns clockwise.
    public mutating func add(_ probabilities: [[Double]]) {
        precondition(probabilities.count == 4)
        for truthTurns in 0..<4 {
            // The photo as it sits in the library needs `truth`; in pass r it is turned by r, so it needs truth - r.
            var scores: [Rotation: Double] = [:]
            for pass in 0..<4 {
                let p = probabilities[(truthTurns - pass + 4) % 4]
                scores.merge(OrientationClassifier.passScores(p, pass: Rotation(degrees: 90 * pass))) { $0 + $1 }
            }
            let decision = decider.decide([DetectorEvidence(detector: "model", weight: weight, uprightScores: scores)])
            let truth = Rotation(degrees: 90 * truthTurns)
            if truth == Rotation.none { uprightCases += 1 } else { rotatedCases += 1 }
            for (t, threshold) in Self.thresholds.enumerated() {
                guard decision.status == .needsRotation, decision.confidence >= threshold else { continue }
                if truth == Rotation.none {
                    falseProposals[t] += 1
                } else if decision.rotation == truth {
                    correctProposals[t] += 1
                } else {
                    wrongDirection[t] += 1
                }
            }
        }
    }

    public func report(title: String) -> String {
        func pct(_ n: Int, _ total: Int, width: Int) -> String {
            let text = total == 0 ? "—" : String(format: "%.1f%%", 100 * Double(n) / Double(total))
            return String(repeating: " ", count: max(0, width - text.count)) + text
        }
        var lines = ["\(title): \(uprightCases) upright and \(rotatedCases) rotated test cases",
                     "  min confidence | rotated: found correctly | rotated: wrong direction | upright: wrongly proposed"]
        for (t, threshold) in Self.thresholds.enumerated() {
            lines.append(String(format: "  %13.0f%%", threshold * 100)
                + " | " + pct(correctProposals[t], rotatedCases, width: 24)
                + " | " + pct(wrongDirection[t], rotatedCases, width: 24)
                + " | " + pct(falseProposals[t], uprightCases, width: 25))
        }
        return lines.joined(separator: "\n")
    }
}
