import CoreGraphics
import RotatorCore
import Vision

/// Vision's image feature print: a 768-number summary of what a picture shows, from a network trained on upright
/// photos. Rotating a photo changes its feature print in consistent ways, which is what the scene orientation
/// classifier learns to read.
///
/// The app and the training tool both use this type, so the features the model was trained on are computed exactly
/// the way the app computes them.
public enum SceneFeatures {
    /// Pinned: a different revision produces different features and would silently invalidate the trained model.
    public static let revision = VNGenerateImageFeaturePrintRequestRevision2
    public static let dimension = 768

    public static func makeRequest() -> VNGenerateImageFeaturePrintRequest {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        request.imageCropAndScaleOption = .scaleFill
        return request
    }

    /// The feature vector from a performed request, or `nil` if Vision produced nothing usable.
    public static func vector(from request: VNRequest) -> [Float]? {
        guard let observation = request.results?.first as? VNFeaturePrintObservation,
              observation.elementCount == dimension
        else { return nil }
        let data = observation.data
        switch observation.elementType {
        case .float:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(dimension)) }
        case .double:
            return data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(dimension).map(Float.init) }
        default:
            return nil
        }
    }

    /// The features of `image` after rotating it clockwise by `rotation`.
    public static func features(of image: CGImage, rotatedBy rotation: Rotation) throws -> [Float]? {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image, orientation: rotation.cgOrientation, options: [:]).perform([request])
        return vector(from: request)
    }
}
