import CoreML
import Foundation
import RotatorCore
import Vision

/// The fine-tuned orientation network (see Tools/TrainOrientationNet): a 224×224 image in, probabilities for how
/// many quarter turns clockwise the image needs, labelled "0", "90", "180" and "270".
///
/// Vision applies the analysis pass's orientation first and then squashes the frame to 224×224, which is exactly how
/// the training images were prepared.
public final class OrientationNetwork: @unchecked Sendable {
    public let model: VNCoreMLModel

    public init(compiledModelAt url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
    }

    /// Loads a `.mlmodelc`, or compiles an `.mlpackage`/`.mlmodel` first. Compiled copies of packages are cached
    /// (in `cacheDirectory`, keyed by the package's modification date) so compilation happens once.
    public static func load(from url: URL, cacheDirectory: URL? = nil) throws -> OrientationNetwork {
        if url.pathExtension == "mlmodelc" { return try OrientationNetwork(compiledModelAt: url) }
        guard let cacheDirectory else {
            return try OrientationNetwork(compiledModelAt: try MLModel.compileModel(at: url))
        }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .map { Int($0.timeIntervalSince1970) } ?? 0
        let cached = cacheDirectory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(stamp).mlmodelc")
        if !FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let compiled = try MLModel.compileModel(at: url)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.moveItem(at: compiled, to: cached)
        }
        return try OrientationNetwork(compiledModelAt: cached)
    }

    public func makeRequest() -> VNCoreMLRequest {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        return request
    }

    /// Probabilities indexed by quarter turns clockwise needed, or `nil` if the request produced nothing usable.
    public static func probabilities(from request: VNRequest) -> [Double]? {
        guard let observations = request.results as? [VNClassificationObservation], !observations.isEmpty else { return nil }
        var p = [Double](repeating: 0, count: 4)
        for observation in observations {
            guard let degrees = Int(observation.identifier), degrees % 90 == 0, (0..<360).contains(degrees) else { continue }
            p[degrees / 90] = Double(observation.confidence)
        }
        let total = p.reduce(0, +)
        guard total > 0 else { return nil }
        return p.map { $0 / total }
    }

    /// The probabilities for `image` after turning it clockwise by `rotation`.
    public func probabilities(of image: CGImage, rotatedBy rotation: Rotation) throws -> [Double]? {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image, orientation: rotation.cgOrientation, options: [:]).perform([request])
        return Self.probabilities(from: request)
    }
}
