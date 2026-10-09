import AppKit
import ImageIO
import UniformTypeIdentifiers
import RotatorVision
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
        settings.useScene = false
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

    /// The fine-tuned network on its own, through the app's analyzer: a clear portrait must never be turned the wrong
    /// way. Skipped until a trained model has been committed to Models/.
    func testOrientationNetworkOnAPortrait() throws {
        let upright = try uprightPhoto()
        let modelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models/OrientationNet.mlpackage")
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw XCTSkip("No trained network in Models/") }
        var analyzer = analyzer(faces: false, body: false)
        analyzer.stages = [[OrientationNetDetector(network: try OrientationNetwork.load(from: modelURL))]]
        for turns in 0...3 {
            let image = OrientationPipelineTests.turnedCounterClockwise(upright, quarterTurns: turns)
            let expected = Rotation(degrees: 90 * turns)
            let result = try analyzer.analyze(image)
            print("network only, turned \(turns * 90)° CCW → \(result.decision.rotation) \(result.decision.status) conf=\(result.decision.confidence) [\(result.summary)]")
            if result.decision.status == .needsRotation || result.decision.status == .upright {
                XCTAssertEqual(result.decision.rotation, expected, result.summary)
            }
        }
    }

    /// A photo stored sideways with an orientation tag, as iPhones save portrait photos, must be analysed the way it
    /// is displayed. The app gets photos from PhotoKit as `NSImage`s.
    func testTaggedPhotoIsAnalysedAsDisplayed() throws {
        let upright = try uprightPhoto()
        // Stored turned a quarter turn counter-clockwise; EXIF orientation 6 says "turn 90° clockwise to display".
        let stored = OrientationPipelineTests.turnedCounterClockwise(upright, quarterTurns: 1)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, stored, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try XCTUnwrap(NSImage(data: data as Data))

        let analyzer = analyzer(faces: true, body: false)
        if let shortcut = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let result = try analyzer.analyze(shortcut)
            print("NSImage.cgImage shortcut → \(result.decision.rotation) \(result.decision.status) [\(result.summary)]")
        }
        let drawn = try XCTUnwrap(PhotoLibrary.displayedPixels(of: image, maxLongEdge: 768))
        let result = try analyzer.analyze(drawn)
        print("drawn as displayed → \(result.decision.rotation) \(result.decision.status) [\(result.summary)]")
        XCTAssertEqual(result.decision.status, .upright, result.summary)
    }
}
