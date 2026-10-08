import CoreML
import Foundation
import RotatorCore
import Vision

/// A Vision-based signal for "this frame looks upright".
///
/// The analyzer shows every detector the same photo four times (once per candidate correction, by passing an
/// EXIF orientation to `VNImageRequestHandler`), then asks it to score each pass. Because every score is about
/// the frame Vision analysed, detectors never need to know which way a rotation's sign runs.
protocol OrientationDetector: Sendable {
    var name: String { get }
    var weight: Double { get }
    func makeRequest() -> VNRequest
    /// How strongly the results of `request` indicate that the analysed frame is upright, in `0...1`.
    /// `frameSize` is the pixel size of the frame Vision analysed (already rotated).
    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double
}

/// Faces are the strongest cue: Vision's face detector finds faces at any in-plane angle and reports their roll,
/// so only the pass in which a face's roll is near zero gets credit.
struct FaceDetector: OrientationDetector {
    let name = "faces"
    let weight = 1.0

    func makeRequest() -> VNRequest {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let faces = request.results as? [VNFaceObservation] else { return 0 }
        return noisyOr(faces.compactMap { face -> Double? in
            // Ignore specks: tiny "faces" in a thumbnail are mostly false positives.
            guard face.boundingBox.width * face.boundingBox.height >= 0.0025 else { return nil }
            // Without roll every pass would find the face equally, which the decider treats as a tie.
            let upright = face.roll.map { uprightFactor(angleFromVertical: $0.doubleValue, toleranceDegrees: 30) } ?? 1
            return Double(face.confidence) * upright
        })
    }
}

/// People seen from behind or far away: credit the pass in which the neck is above the hips.
struct BodyPoseDetector: OrientationDetector {
    let name = "body"
    let weight = 0.8

    func makeRequest() -> VNRequest { VNDetectHumanBodyPoseRequest() }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let bodies = request.results as? [VNHumanBodyPoseObservation] else { return 0 }
        return noisyOr(bodies.compactMap { body -> Double? in
            guard let top = joint(body, .neck) ?? joint(body, .nose),
                  let bottom = joint(body, .root) ?? hipCenter(body)
            else { return nil }
            // Vision's normalised coordinates have their origin at the bottom left, y pointing up.
            let dx = Double(top.location.x - bottom.location.x) * frameSize.width
            let dy = Double(top.location.y - bottom.location.y) * frameSize.height
            guard hypot(dx, dy) > 4 else { return nil }
            let angleFromUp = atan2(dx, dy)
            return min(top.confidence, bottom.confidence) * uprightFactor(angleFromVertical: angleFromUp, toleranceDegrees: 35)
        })
    }

    private struct Joint {
        var location: CGPoint
        var confidence: Double
    }

    private func joint(_ body: VNHumanBodyPoseObservation, _ name: VNHumanBodyPoseObservation.JointName) -> Joint? {
        guard let p = try? body.recognizedPoint(name), p.confidence > 0.3 else { return nil }
        return Joint(location: p.location, confidence: Double(p.confidence))
    }

    private func hipCenter(_ body: VNHumanBodyPoseObservation) -> Joint? {
        guard let l = joint(body, .leftHip), let r = joint(body, .rightHip) else { return nil }
        return Joint(
            location: CGPoint(x: (l.location.x + r.location.x) / 2, y: (l.location.y + r.location.y) / 2),
            confidence: min(l.confidence, r.confidence)
        )
    }
}

/// Signs, documents, screens: Vision's fast text recogniser reads upright text far more confidently than
/// sideways or upside-down text.
struct TextDetector: OrientationDetector {
    let name = "text"
    let weight = 0.7

    func makeRequest() -> VNRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        return request
    }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let lines = request.results as? [VNRecognizedTextObservation] else { return 0 }
        var mass = 0.0
        for line in lines {
            guard let candidate = line.topCandidates(1).first, candidate.confidence >= 0.5 else { continue }
            let readable = candidate.string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            guard readable >= 3 else { continue }
            mass += Double(candidate.confidence) * min(Double(readable) / 8, 1)
        }
        // Saturates: ~3 confidently-read words is strong evidence.
        return 1 - exp(-mass / 1.5)
    }
}

/// Optional: any Core ML image classifier that has an "upright" class (labelled `0`, `0°`, `up` or `upright`).
/// The score of a pass is the probability the model gives that class. This extends coverage to photos with no
/// people or text (landscapes, objects), which the built-in Vision detectors cannot judge.
struct CoreMLDetector: OrientationDetector, @unchecked Sendable {
    let name = "model"
    let weight = 1.0
    let model: VNCoreMLModel

    static let uprightLabels: Set<String> = ["0", "0°", "0deg", "rot0", "up", "upright", "none", "normal"]

    static func load(from url: URL) async throws -> CoreMLDetector {
        var modelURL = url
        if url.pathExtension.lowercased() != "mlmodelc" {
            modelURL = try await MLModel.compileModel(at: url)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
        return CoreMLDetector(model: try VNCoreMLModel(for: mlModel))
    }

    func makeRequest() -> VNRequest {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        return request
    }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let classes = request.results as? [VNClassificationObservation] else { return 0 }
        let upright = classes.first { Self.uprightLabels.contains($0.identifier.lowercased().trimmingCharacters(in: .whitespaces)) }
        return Double(upright?.confidence ?? 0)
    }
}
