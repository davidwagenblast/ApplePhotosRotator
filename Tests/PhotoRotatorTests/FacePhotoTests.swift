import ImageIO
import XCTest
@testable import PhotoRotator
@testable import RotatorCore

/// Runs the detectors on a real photo of a person, turned to each orientation.
/// CI downloads a public-domain NASA portrait and passes its path in `FACE_IMAGE`; locally the tests are skipped
/// unless you set it to any upright photo of a person.
final class FacePhotoTests: XCTestCase {
    private func uprightPhoto() throws -> CGImage {
        guard let path = ProcessInfo.processInfo.environment["FACE_IMAGE"],
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw XCTSkip("Set FACE_IMAGE to an upright photo of a person") }
        return image
    }

    private func analyzer(faces: Bool, body: Bool) -> OrientationAnalyzer {
        var settings = ScanSettings()
        settings.useFaces = faces
        settings.useBodyPose = body
        settings.useText = false
        return OrientationAnalyzer(settings: settings, model: nil)
    }

    func testFacePhotoIsCorrectedInEveryOrientation() throws {
        let upright = try uprightPhoto()
        let analyzer = analyzer(faces: true, body: true)
        for turns in 0...3 {
            let image = OrientationPipelineTests.turnedCounterClockwise(upright, quarterTurns: turns)
            let expected = Rotation(degrees: 90 * turns)
            let result = try analyzer.analyze(image)
            print("faces+body, turned \(turns * 90)° CCW → \(result.decision.rotation) \(result.decision.status) conf=\(result.decision.confidence) [\(result.summary)]")
            XCTAssertEqual(result.decision.rotation, expected, result.summary)
            XCTAssertEqual(result.decision.status, turns == 0 ? .upright : .needsRotation, result.summary)
            XCTAssertGreaterThan(result.decision.confidence, 0.5, result.summary)
        }
    }

    /// Body pose on its own may be unsure about a head-and-shoulders portrait, but it must never point the wrong way.
    func testBodyPoseAloneIsNeverWrong() throws {
        let upright = try uprightPhoto()
        let analyzer = analyzer(faces: false, body: true)
        for turns in 0...3 {
            let image = OrientationPipelineTests.turnedCounterClockwise(upright, quarterTurns: turns)
            let expected = Rotation(degrees: 90 * turns)
            let result = try analyzer.analyze(image)
            print("body only, turned \(turns * 90)° CCW → \(result.decision.rotation) \(result.decision.status) conf=\(result.decision.confidence) [\(result.summary)]")
            if result.decision.status == .needsRotation || result.decision.status == .upright {
                XCTAssertEqual(result.decision.rotation, expected, result.summary)
            }
        }
    }
}
