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
        // Faces first: one Vision request per photo, and usually decisive when present.
        if settings.useFaces { stages.append([FaceDetector()]) }
        if settings.useBodyPose { stages.append([BodyPoseDetector()]) }
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

    /// One `VNImageRequestHandler` per candidate orientation, with all of a stage's requests performed together so
    /// Vision prepares each oriented image only once. Detectors that run once only take part in the first pass.
    private func run(_ detectors: [any OrientationDetector], on image: CGImage) throws -> [DetectorEvidence] {
        var scores = Array(repeating: [Rotation: Double](), count: detectors.count)
        let passes: [Rotation] = detectors.allSatisfy(\.runsOnce) ? [Rotation.none] : Rotation.allCases
        for pass in passes {
            let active = detectors.indices.filter { pass == Rotation.none || !detectors[$0].runsOnce }
            let size = pass.swapsDimensions
                ? CGSize(width: image.height, height: image.width)
                : CGSize(width: image.width, height: image.height)
            let requests = active.map { detectors[$0].makeRequest() }
            let handler = VNImageRequestHandler(cgImage: image, orientation: pass.cgOrientation, options: [:])
            try handler.perform(requests)
            for (request, i) in zip(requests, active) {
                scores[i].merge(detectors[i].uprightScores(of: request, frameSize: size, pass: pass)) { max($0, $1) }
            }
        }
        return detectors.enumerated().map { i, d in
            DetectorEvidence(detector: d.name, weight: d.weight, uprightScores: scores[i])
        }
    }
}
