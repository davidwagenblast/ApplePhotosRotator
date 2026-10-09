import Foundation

/// Scores held-out photos exactly the way the app judges them — four passes averaged, then `OrientationDecider` —
/// and tallies what a person reviewing the results would see at each minimum-confidence setting.
public struct OrientationEvaluation {
    public static let thresholds = [0.3, 0.5, 0.6, 0.7, 0.8, 0.9]

    public var weight: Double
    public var prior: OrientationPrior
    /// Only propose a turn when every one of the four passes, on its own, points to it.
    public var requireAgreement: Bool

    public private(set) var uprightCases = 0
    public private(set) var sidewaysCases = 0
    public private(set) var upsideDownCases = 0
    public private(set) var falseProposals: [Int]
    public private(set) var sidewaysFound: [Int]
    public private(set) var upsideDownFound: [Int]
    public private(set) var wrongDirection: [Int]
    private let decider = OrientationDecider()

    public init(weight: Double, prior: OrientationPrior = .equal, requireAgreement: Bool = false) {
        self.weight = weight
        self.prior = prior
        self.requireAgreement = requireAgreement
        falseProposals = Array(repeating: 0, count: Self.thresholds.count)
        sidewaysFound = falseProposals
        upsideDownFound = falseProposals
        wrongDirection = falseProposals
    }

    public var rotatedCases: Int { sidewaysCases + upsideDownCases }

    /// Adds one upright photo, tested in all four orientations. `probabilities[m]` are the model's four class
    /// probabilities for the photo turned so that it needs `m` quarter turns clockwise.
    public mutating func add(_ probabilities: [[Double]]) {
        precondition(probabilities.count == 4)
        for truthTurns in 0..<4 {
            // The photo as it sits in the library needs `truth`; in pass r it is turned by r, so it needs truth - r.
            var scores: [Rotation: Double] = [:]
            var passVotes = Set<Rotation>()
            for pass in 0..<4 {
                let p = probabilities[(truthTurns - pass + 4) % 4]
                let passScores = OrientationClassifier.passScores(p, pass: Rotation(degrees: 90 * pass))
                passVotes.insert(passScores.max { $0.value < $1.value }!.key)
                scores.merge(passScores) { $0 + $1 }
            }
            let decision = decider.decide([
                DetectorEvidence(detector: "model", weight: weight, uprightScores: prior.apply(to: scores))
            ])
            let unanimous = passVotes.count == 1
            let truth = Rotation(degrees: 90 * truthTurns)
            switch truth {
            case .none: uprightCases += 1
            case .rotate180: upsideDownCases += 1
            default: sidewaysCases += 1
            }
            for (t, threshold) in Self.thresholds.enumerated() {
                guard decision.status == .needsRotation, decision.confidence >= threshold,
                      !requireAgreement || unanimous
                else { continue }
                if truth == Rotation.none {
                    falseProposals[t] += 1
                } else if decision.rotation != truth {
                    wrongDirection[t] += 1
                } else if truth == .rotate180 {
                    upsideDownFound[t] += 1
                } else {
                    sidewaysFound[t] += 1
                }
            }
        }
    }

    public func report(title: String) -> String {
        func pct(_ n: Int, _ total: Int, width: Int) -> String {
            let text = total == 0 ? "—" : String(format: "%.1f%%", 100 * Double(n) / Double(total))
            return String(repeating: " ", count: max(0, width - text.count)) + text
        }
        var lines = ["\(title): \(uprightCases) upright, \(sidewaysCases) sideways and \(upsideDownCases) upside-down test cases",
                     "  min confidence | sideways found | upside-down found | wrong direction | upright wrongly flagged"]
        for (t, threshold) in Self.thresholds.enumerated() {
            lines.append(String(format: "  %13.0f%%", threshold * 100)
                + " | " + pct(sidewaysFound[t], sidewaysCases, width: 14)
                + " | " + pct(upsideDownFound[t], upsideDownCases, width: 17)
                + " | " + pct(wrongDirection[t], rotatedCases, width: 15)
                + " | " + pct(falseProposals[t], uprightCases, width: 23))
        }
        return lines.joined(separator: "\n")
    }
}
