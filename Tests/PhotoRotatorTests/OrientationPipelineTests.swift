import CoreImage
import CoreText
import ImageIO
import XCTest
@testable import PhotoRotator
@testable import RotatorCore
import RotatorVision

/// Exercises the real Vision pipeline on synthetic images, without a Photos library.
///
/// The test images are turned with plain Core Graphics transforms, independent of the EXIF mapping the app uses,
/// so these tests check that the app proposes the right *direction* and that applying it really makes the
/// image upright.
final class OrientationPipelineTests: XCTestCase {
    private var analyzer: OrientationAnalyzer {
        var settings = ScanSettings()
        settings.useFaces = false
        settings.useBodyPose = false
        settings.useText = true
        return OrientationAnalyzer(settings: settings, model: nil)
    }

    func testUprightTextIsLeftAlone() throws {
        let result = try analyzer.analyze(Self.textImage())
        XCTAssertEqual(result.decision.status, .upright, result.summary)
        XCTAssertEqual(result.decision.rotation, Rotation.none)
    }

    func testDetectsEachRotationAndApplyingItMakesTheImageUpright() throws {
        let upright = Self.textImage()
        for quarterTurns in 1...3 {
            // Turned counter-clockwise by k quarter turns, so the fix is k quarter turns clockwise.
            let turned = Self.turnedCounterClockwise(upright, quarterTurns: quarterTurns)
            let expected = Rotation(degrees: 90 * quarterTurns)

            let result = try analyzer.analyze(turned)
            XCTAssertEqual(result.decision.status, .needsRotation, "\(expected): \(result.summary)")
            XCTAssertEqual(result.decision.rotation, expected, result.summary)

            // Apply the proposal the same way RotationApplier does, then check the result reads as upright.
            let fixed = try XCTUnwrap(Self.render(CIImage(cgImage: turned).oriented(expected.cgOrientation)))
            XCTAssertEqual(fixed.width, upright.width)
            XCTAssertEqual(fixed.height, upright.height)
            let after = try analyzer.analyze(fixed)
            XCTAssertEqual(after.decision.status, .upright, "after applying \(expected): \(after.summary)")
        }
    }

    func testBlankImageIsInconclusive() throws {
        let blank = Self.canvas(width: 600, height: 400) { _ in }
        XCTAssertEqual(try analyzer.analyze(blank).decision.status, .inconclusive)
    }

    func testMetadataIsKeptButOrientationAndSizeAreReset() {
        let source: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyPixelWidth: 4000,
            kCGImagePropertyPixelHeight: 3000,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFModel: "iPhone"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2019:07:04 12:00:00",
                kCGImagePropertyExifPixelXDimension: 4000,
                kCGImagePropertyExifPixelYDimension: 3000,
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33] as [CFString: Any],
        ]
        let out = RotationApplier.metadata(source, width: 3000, height: 4000)
        XCTAssertEqual(out[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertNil(out[kCGImagePropertyPixelWidth])
        let tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation] as? Int, 1)
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "iPhone")
        let exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2019:07:04 12:00:00")
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension] as? Int, 3000)
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelYDimension] as? Int, 4000)
        let gps = out[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude] as? Double, 37.33)
    }

    // MARK: Synthetic images

    private static func canvas(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    /// A 900×600 page of large black text, upright.
    static func textImage() -> CGImage {
        canvas(width: 900, height: 600) { context in
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 54, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
            let lines = ["THE QUICK BROWN FOX", "JUMPS OVER THE LAZY", "DOG NEAR THE RIVER", "PHOTO ROTATOR TEST"]
            for (i, text) in lines.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 40, y: 480 - i * 130)
                CTLineDraw(line, context)
            }
        }
    }

    /// Turns an image counter-clockwise by whole quarter turns using a Core Graphics transform.
    static func turnedCounterClockwise(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let angle = CGFloat(quarterTurns) * .pi / 2
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            .applying(CGAffineTransform(rotationAngle: angle))
        return canvas(width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded())) { context in
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.rotate(by: angle) // Positive is counter-clockwise in Core Graphics' y-up space.
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    static func render(_ image: CIImage) -> CGImage? {
        let moved = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return CIContext().createCGImage(moved, from: moved.extent)
    }
}
