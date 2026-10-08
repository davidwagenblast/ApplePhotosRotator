import CoreGraphics
import RotatorCore
import Vision

/// Vision's image feature print: a 768-number summary of what a picture shows. The scene model pairs it with
/// `GridFeatures`, which say where things are.
///
/// The app and the training tool both use this type, so the features the model was trained on are computed exactly
/// the way the app computes them.
public enum SceneFeatures {
    /// Pinned: a different revision produces different features and would silently invalidate the trained model.
    public static let revision = VNGenerateImageFeaturePrintRequestRevision2
    public static let printDimension = 768

    /// Regions of the analysed frame to describe, in Vision's normalised coordinates (origin bottom-left).
    ///
    /// Only the whole photo: adding the top and bottom halves was tried and measured — single-pass accuracy on
    /// held-out photos stayed at 73.8% and the precision/recall trade-off was unchanged — so it isn't worth three
    /// times the work per photo.
    public static let regions = [CGRect(x: 0, y: 0, width: 1, height: 1)]

    public static var dimension: Int { printDimension * regions.count }

    public static func makeRequests() -> [VNRequest] {
        regions.map { region in
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = revision
            request.imageCropAndScaleOption = .scaleFill
            request.regionOfInterest = region
            return request
        }
    }

    /// The concatenated feature vectors from performed `makeRequests()`, or `nil` if Vision produced nothing usable.
    public static func vector(from requests: [VNRequest]) -> [Float]? {
        guard requests.count == regions.count else { return nil }
        var result: [Float] = []
        result.reserveCapacity(dimension)
        for request in requests {
            guard let print = printVector(from: request) else { return nil }
            result += print
        }
        return result
    }

    static func printVector(from request: VNRequest) -> [Float]? {
        guard let observation = request.results?.first as? VNFeaturePrintObservation,
              observation.elementCount == printDimension
        else { return nil }
        let data = observation.data
        switch observation.elementType {
        case .float:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(printDimension)) }
        case .double:
            return data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(printDimension).map(Float.init) }
        default:
            return nil
        }
    }

    /// The features of `image` after rotating it clockwise by `rotation`.
    public static func features(of image: CGImage, rotatedBy rotation: Rotation) throws -> [Float]? {
        let requests = makeRequests()
        try VNImageRequestHandler(cgImage: image, orientation: rotation.cgOrientation, options: [:]).perform(requests)
        return vector(from: requests)
    }
}
