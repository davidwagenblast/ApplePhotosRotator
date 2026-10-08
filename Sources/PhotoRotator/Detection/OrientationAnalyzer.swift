import CoreGraphics
import Foundation
import RotatorCore
import Vision

/// Runs the detectors over one image and decides whether it needs rotating.
///
/// Detectors run in stages, cheapest and most reliable first. If a stage already produces a confident answer the
/// remaining stages are skipped, which matters when the same work is repeated 250,000 times.
struct OrientationAnalyzer: Sendable {
    var stages: [[any OrientationDetector]]
    var decider: OrientationDecider
    /// Stop after a stage once the decision is at least this confident.
    var earlyExitConfidence: Double = 0.8

    struct Result: Sendable {
        var decision: OrientationDecision
        var evidence: [DetectorEvidence]

        /// A compact human-readable summary such as `faces 90°:0.97 · text 90°:0.40`.
        var summary: String {
            evidence.compactMap { e -> String? in
                guard let best = Rotation.allCases.max(by: { e.score(for: $0) < e.score(for: $1) }),
                      e.score(for: best) > 0.05 else { return nil }
                return "\(e.detector) \(best.degrees)°:\(String(format: "%.2f", e.score(for: best)))"
            }.joined(separator: " · ")
        }
    }

    init(settings: ScanSettings, model: CoreMLDetector?) {
        var stages: [[any OrientationDetector]] = []
        var first: [any OrientationDetector] = []
        if settings.useFaces { first.append(FaceDetector()) }
        if settings.useBodyPose { first.append(BodyPoseDetector()) }
        if !first.isEmpty { stages.append(first) }
        if settings.useText { stages.append([TextDetector()]) }
        if let model { stages.append([model]) }
        self.stages = stages
        self.decider = OrientationDecider(minimumStrength: 0.3, minimumConfidence: 0.2)
    }

    func analyze(_ image: CGImage) throws -> Result {
        var evidence: [DetectorEvidence] = []
        var decision = decider.decide([])
        for stage in stages {
            evidence += try run(stage, on: image)
            decision = decider.decide(evidence)
            if decision.confidence >= earlyExitConfidence { break }
        }
        return Result(decision: decision, evidence: evidence)
    }

    /// One `VNImageRequestHandler` per candidate orientation, all of a stage's requests performed together so
    /// Vision only has to prepare each oriented image once.
    private func run(_ detectors: [any OrientationDetector], on image: CGImage) throws -> [DetectorEvidence] {
        var scores = Array(repeating: [Rotation: Double](), count: detectors.count)
        for rotation in Rotation.allCases {
            let size = rotation.swapsDimensions
                ? CGSize(width: image.height, height: image.width)
                : CGSize(width: image.width, height: image.height)
            let requests = detectors.map { $0.makeRequest() }
            let handler = VNImageRequestHandler(cgImage: image, orientation: rotation.cgOrientation, options: [:])
            try handler.perform(requests)
            for (i, detector) in detectors.enumerated() {
                scores[i][rotation] = detector.uprightScore(of: requests[i], frameSize: size)
            }
        }
        return detectors.enumerated().map { i, d in
            DetectorEvidence(detector: d.name, weight: d.weight, uprightScores: scores[i])
        }
    }
}
