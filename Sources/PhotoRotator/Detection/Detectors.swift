import AppKit
import CoreML
import Foundation
import RotatorCore
import RotatorVision
import Vision

/// A Vision-based signal for which correction makes a photo upright.
///
/// Scores are in `0...1` per candidate correction: 0 means "no upright content found after this correction",
/// 1 means "certainly upright".
protocol OrientationDetector: Sendable {
    var name: String { get }
    var weight: Double { get }
    /// `true` for detectors that find their subject at any angle and report that angle (faces). They run once, on
    /// the photo as displayed, and score every correction from that single result. Other detectors are shown the
    /// photo once per candidate correction.
    var runsOnce: Bool { get }
    func makeRequests() -> [VNRequest]
    /// Scores keyed by correction. `pass` is the correction Vision applied before analysing, `image` is the photo
    /// as displayed (before that correction), and `frameSize` is the pixel size of the frame Vision analysed.
    func uprightScores(of requests: [VNRequest], image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double]
    /// Adjusts the scores summed over all passes before they are combined with other detectors.
    func finalScores(_ scores: [Rotation: Double]) -> [Rotation: Double]
}

extension OrientationDetector {
    func finalScores(_ scores: [Rotation: Double]) -> [Rotation: Double] { scores }
}

/// Most detectors need a single Vision request per pass.
protocol SingleRequestDetector: OrientationDetector {
    func makeRequest() -> VNRequest
    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double]
}

extension SingleRequestDetector {
    func makeRequests() -> [VNRequest] { [makeRequest()] }

    func uprightScores(of requests: [VNRequest], image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        requests.first.map { uprightScores(of: $0, image: image, frameSize: frameSize, pass: pass) } ?? [:]
    }
}

/// A detector that only recognises upright content. It is run on all four orientations, and the orientation in
/// which it finds upright content gets the credit. Because every score is about the frame Vision analysed, the
/// detector never needs to know which way a rotation's sign runs.
protocol PerPassDetector: SingleRequestDetector {
    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double
}

extension PerPassDetector {
    var runsOnce: Bool { false }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        [pass: uprightScore(of: request, frameSize: frameSize)]
    }
}

/// Faces are the strongest cue. Vision's face detector finds faces at any in-plane angle and reports their roll,
/// so one pass is enough: a face rolled by about +90° means the photo needs 90° clockwise, and so on.
struct FaceDetector: SingleRequestDetector {
    let name = "faces"
    let weight = 1.0
    let runsOnce = true

    func makeRequest() -> VNRequest {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        guard let faces = request.results as? [VNFaceObservation] else { return [:] }
        var votes: [Rotation: [Double]] = [:]
        for face in faces {
            // Ignore specks: tiny "faces" in a thumbnail are mostly false positives.
            guard face.boundingBox.width * face.boundingBox.height >= 0.0025,
                  let roll = face.roll?.doubleValue
            else { continue }
            // Roll is relative to the analysed frame, so add the correction already applied for this pass.
            let degrees = roll * 180 / .pi + Double(pass.degrees)
            let correction = Rotation(degrees: Int(degrees.rounded()))
            // Faces tilted 30–45° from any quarter turn are ambiguous; they don't vote.
            let tilt = (degrees - Double(correction.degrees)) * .pi / 180
            let certainty = Double(face.confidence) * uprightFactor(angleFromVertical: tilt, toleranceDegrees: 30)
            if certainty > 0 { votes[correction, default: []].append(certainty) }
        }
        return votes.mapValues { noisyOr($0) }
    }
}

/// People: credit the orientation in which the body points up — neck above hips, or for head-and-shoulders shots,
/// nose above neck.
struct BodyPoseDetector: PerPassDetector {
    let name = "body"
    let weight = 0.8

    func makeRequest() -> VNRequest { VNDetectHumanBodyPoseRequest() }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let bodies = request.results as? [VNHumanBodyPoseObservation] else { return 0 }
        return noisyOr(bodies.compactMap { body -> Double? in
            guard let (top, bottom) = axis(of: body) else { return nil }
            // Vision's normalised coordinates have their origin at the bottom left, y pointing up.
            let dx = Double(top.location.x - bottom.location.x) * frameSize.width
            let dy = Double(top.location.y - bottom.location.y) * frameSize.height
            guard hypot(dx, dy) > 0.03 * max(frameSize.width, frameSize.height) else { return nil }
            let angleFromUp = atan2(dx, dy)
            return min(top.confidence, bottom.confidence) * uprightFactor(angleFromVertical: angleFromUp, toleranceDegrees: 35)
        })
    }

    private struct Joint {
        var location: CGPoint
        var confidence: Double
    }

    /// The longest reliable head-to-toe direction available.
    private func axis(of body: VNHumanBodyPoseObservation) -> (top: Joint, bottom: Joint)? {
        if let top = joint(body, .neck) ?? joint(body, .nose),
           let bottom = joint(body, .root) ?? center(joint(body, .leftHip), joint(body, .rightHip)) {
            return (top, bottom)
        }
        if let top = joint(body, .nose) ?? center(joint(body, .leftEye), joint(body, .rightEye)),
           let bottom = joint(body, .neck) ?? center(joint(body, .leftShoulder), joint(body, .rightShoulder)) {
            return (top, bottom)
        }
        return nil
    }

    private func joint(_ body: VNHumanBodyPoseObservation, _ name: VNHumanBodyPoseObservation.JointName) -> Joint? {
        guard let p = try? body.recognizedPoint(name), p.confidence > 0.3 else { return nil }
        return Joint(location: p.location, confidence: Double(p.confidence))
    }

    private func center(_ a: Joint?, _ b: Joint?) -> Joint? {
        guard let a, let b else { return nil }
        return Joint(
            location: CGPoint(x: (a.location.x + b.location.x) / 2, y: (a.location.y + b.location.y) / 2),
            confidence: min(a.confidence, b.confidence)
        )
    }
}

/// Signs, documents, screens. Vision reads sideways text not at all, and upside-down text as gibberish with the
/// *same* confidence as real text, so the score counts recognised dictionary words, not Vision's confidence.
struct TextDetector: PerPassDetector {
    let name = "text"
    let weight = 0.7

    func makeRequest() -> VNRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        // Correction would "fix" upside-down gibberish into words, hiding exactly the signal we need.
        request.usesLanguageCorrection = false
        return request
    }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let lines = request.results as? [VNRecognizedTextObservation], !lines.isEmpty else { return 0 }
        let text = lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let (words, real) = Lexicon.count(in: text)
        guard words > 0 else { return 0 }
        // Mostly real words, and enough of them: ~3 real words is strong evidence.
        return (Double(real) / Double(words)) * (1 - exp(-Double(real) / 2))
    }
}

/// Dictionary lookups via the system spell checker, in the user's languages.
enum Lexicon {
    private static let lock = NSLock()

    /// Words of 3+ characters, and how many of them are spelled correctly. Tokens mixing letters and digits
    /// ("IS31", "OIOHd" style misreads) count as words but never as real ones.
    static func count(in text: String) -> (words: Int, real: Int) {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) }
        guard !tokens.isEmpty else { return (0, 0) }
        // NSSpellChecker is not thread-safe; the text stage is rare enough that serialising it costs little.
        lock.lock()
        defer { lock.unlock() }
        let checker = NSSpellChecker.shared
        let real = tokens.filter { token in
            guard token.allSatisfy(\.isLetter) else { return false }
            // Lower-cased so all-caps gibberish isn't waved through as an acronym.
            let word = token.lowercased()
            return checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        }.count
        return (tokens.count, real)
    }
}

/// Optional: any Core ML image classifier that has an "upright" class (labelled `0`, `0°`, `up` or `upright`).
/// The score of a pass is the probability the model gives that class. This extends coverage to photos with no
/// people or text (landscapes, objects), which the built-in Vision detectors cannot judge.
struct CoreMLDetector: PerPassDetector, @unchecked Sendable {
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

/// Landscapes, buildings, objects — anything. A small classifier, trained on thousands of photos turned all four
/// ways, reads Vision's feature prints of the whole photo and of its top and bottom halves (what is where) together
/// with a coarse colour-and-edge map (sky above ground, horizons, buildings and trees pointing up) and estimates
/// which correction the photo needs.
/// It runs on all four orientations and the four estimates are averaged, which cancels out direction biases.
struct SceneDetector: OrientationDetector {
    let name = "scene"
    let weight = 0.9
    let runsOnce = false
    let classifier: OrientationClassifier

    static let inputSize = SceneFeatures.dimension + GridFeatures.dimension

    /// The model built into the app, or `nil` if it has not been trained into this build.
    static let builtIn: OrientationClassifier? = Data(base64Encoded: SceneModelWeights.encoded)
        .flatMap { try? OrientationClassifier(data: $0) }
        .flatMap { $0.inputSize == inputSize ? $0 : nil }

    func makeRequests() -> [VNRequest] { SceneFeatures.makeRequests() }

    func uprightScores(of requests: [VNRequest], image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        guard let featurePrint = SceneFeatures.vector(from: requests), let grid = SceneGrid.rgb(of: image) else { return [:] }
        let input = featurePrint + GridFeatures.features(grid, rotatedBy: pass)
        return OrientationClassifier.passScores(classifier.probabilities(input), pass: pass)
    }
}

/// The fine-tuned orientation network: an image-recognition network trained specifically to tell which way a photo
/// is turned. It covers every kind of photo — landscapes, buildings, objects, people — and is the main cue for photos
/// without faces. Like the scene model, it runs on all four orientations and averages the four estimates.
struct OrientationNetDetector: SingleRequestDetector {
    let name = "network"
    let weight = 1.0
    let runsOnce = false
    let network: OrientationNetwork

    /// The network was trained with all four turns equally likely; real libraries are mostly upright and rarely
    /// upside down. Measured on held-out photos (Models/OrientationNet-report-coreml.txt), these odds cut wrongly
    /// flagged upright photos from 3% to under 0.1% at 50% confidence, while still finding about half of sideways
    /// photos. In exchange the network alone almost never proposes upside-down turns; faces, people and text
    /// still do.
    static let prior = OrientationPrior(upright: 0.90, sideways: 0.045, upsideDown: 0.01)

    func finalScores(_ scores: [Rotation: Double]) -> [Rotation: Double] { Self.prior.apply(to: scores) }

    /// The network bundled with the app (compiled at build time, or compiled once on first use), or `nil` if this
    /// build doesn't include one. `PHOTO_ROTATOR_ORIENTATION_NET` can point at a model for development.
    static let builtIn: OrientationNetwork? = {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoRotator", isDirectory: true)
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTO_ROTATOR_ORIENTATION_NET"].map { URL(fileURLWithPath: $0) },
            Bundle.main.url(forResource: "OrientationNet", withExtension: "mlmodelc"),
            Bundle.main.url(forResource: "OrientationNet", withExtension: "mlpackage"),
        ]
        for case let url? in candidates {
            if let network = try? OrientationNetwork.load(from: url, cacheDirectory: cache) { return network }
        }
        return nil
    }()

    /// Whether a network is available, without loading (and possibly compiling) it.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["PHOTO_ROTATOR_ORIENTATION_NET"] != nil
            || Bundle.main.url(forResource: "OrientationNet", withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: "OrientationNet", withExtension: "mlpackage") != nil
    }

    func makeRequest() -> VNRequest { network.makeRequest() }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        guard let p = OrientationNetwork.probabilities(from: request) else { return [:] }
        return OrientationClassifier.passScores(p, pass: pass)
    }
}
