import CoreImage
import ImageIO
import Vision
import XCTest
@testable import PhotoRotator
@testable import RotatorCore

/// Prints what Vision reports for each analysis pass. Used to check assumptions about Vision's behaviour.
final class VisionDiagnosticsTests: XCTestCase {
    func testPrintTextObservations() throws {
        let upright = OrientationPipelineTests.textImage()
        for turns in 0...3 {
            let image = OrientationPipelineTests.turnedCounterClockwise(upright, quarterTurns: turns)
            for pass in Rotation.allCases {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image, orientation: pass.cgOrientation).perform([request])
                for o in (request.results ?? []).prefix(2) {
                    let c = o.topCandidates(1).first
                    print(String(format: "DIAG text turnedCCW=%d pass=%d '%@' conf=%.2f TL=(%.2f,%.2f) BL=(%.2f,%.2f) TR=(%.2f,%.2f)",
                                 turns * 90, pass.degrees, c?.string ?? "-", c?.confidence ?? 0,
                                 o.topLeft.x, o.topLeft.y, o.bottomLeft.x, o.bottomLeft.y, o.topRight.x, o.topRight.y))
                }
                if request.results?.isEmpty ?? true {
                    print("DIAG text turnedCCW=\(turns * 90) pass=\(pass.degrees) none")
                }
            }
        }
    }

    func testPrintFaceAndBodyObservations() throws {
        guard let path = ProcessInfo.processInfo.environment["FACE_IMAGE"],
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let upright = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw XCTSkip("Set FACE_IMAGE to a photo of a person") }
        for turns in 0...3 {
            let image = OrientationPipelineTests.turnedCounterClockwise(upright, quarterTurns: turns)
            for pass in Rotation.allCases {
                let face = VNDetectFaceRectanglesRequest()
                face.revision = VNDetectFaceRectanglesRequestRevision3
                let body = VNDetectHumanBodyPoseRequest()
                try VNImageRequestHandler(cgImage: image, orientation: pass.cgOrientation).perform([face, body])
                let faces = (face.results ?? []).map {
                    String(format: "conf=%.2f roll=%@ yaw=%@ area=%.3f", $0.confidence,
                           $0.roll.map { String(format: "%.0f°", $0.doubleValue * 180 / .pi) } ?? "nil",
                           $0.yaw.map { String(format: "%.0f°", $0.doubleValue * 180 / .pi) } ?? "nil",
                           $0.boundingBox.width * $0.boundingBox.height)
                }
                let size = pass.swapsDimensions ? CGSize(width: image.height, height: image.width) : CGSize(width: image.width, height: image.height)
                print("DIAG face turnedCCW=\(turns * 90) pass=\(pass.degrees) faces=\(faces) faceScore=\(String(format: "%.2f", FaceDetector().uprightScore(of: face, frameSize: size))) bodies=\(body.results?.count ?? 0) bodyScore=\(String(format: "%.2f", BodyPoseDetector().uprightScore(of: body, frameSize: size)))")
            }
        }
    }

    func testFacePhotoIsCorrectedInEveryOrientation() throws {
        guard let path = ProcessInfo.processInfo.environment["FACE_IMAGE"],
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let upright = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw XCTSkip("Set FACE_IMAGE to a photo of a person") }
        var settings = ScanSettings()
        settings.useText = false
        let analyzer = OrientationAnalyzer(settings: settings, model: nil)
        for turns in 0...3 {
            let image = OrientationPipelineTests.turnedCounterClockwise(upright, quarterTurns: turns)
            let expected = Rotation(degrees: 90 * turns)
            let result = try analyzer.analyze(image)
            print("DIAG analyzer turnedCCW=\(turns * 90) → \(result.decision) \(result.summary)")
            XCTAssertEqual(result.decision.rotation, expected, result.summary)
            XCTAssertEqual(result.decision.status, turns == 0 ? .upright : .needsRotation, result.summary)
        }
    }
}
