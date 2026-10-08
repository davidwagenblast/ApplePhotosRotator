import CoreImage
import XCTest
@testable import PhotoRotator
@testable import RotatorCore
import RotatorVision

final class SceneGridTests: XCTestCase {
    /// An asymmetric test image: red top-left, green top-right, blue bottom, on grey.
    static func quadrants() -> CGImage {
        let w = 400, h = 300
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.fill(rect)
        }
        fill(0.5, 0.5, 0.5, CGRect(x: 0, y: 0, width: w, height: h))
        // Core Graphics is y-up: the top of the image is at high y.
        fill(1, 0, 0, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        fill(0, 1, 0, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w, height: h / 3))
        return context.makeImage()!
    }

    func testFirstRowIsTheTopOfTheImage() throws {
        let grid = try XCTUnwrap(SceneGrid.rgb(of: Self.quadrants()))
        let n = GridFeatures.side
        XCTAssertGreaterThan(grid[0], 0.9, "top-left is red")
        XCTAssertGreaterThan(grid[(n - 1) * 3 + 1], 0.9, "top-right is green")
        XCTAssertGreaterThan(grid[((n - 1) * n) * 3 + 2], 0.9, "bottom is blue")
    }

    /// The grid rotation must match the EXIF-orientation rotation Vision applies for the same `Rotation`, or the
    /// layout features would describe a different turn than the feature print they are paired with.
    func testGridRotationMatchesVisionOrientation() throws {
        let image = Self.quadrants()
        let grid = try XCTUnwrap(SceneGrid.rgb(of: image))
        let context = CIContext()
        for rotation in Rotation.allCases {
            let oriented = CIImage(cgImage: image).oriented(rotation.cgOrientation)
            let moved = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
            let rendered = try XCTUnwrap(context.createCGImage(moved, from: moved.extent))
            let expected = try XCTUnwrap(SceneGrid.rgb(of: rendered))
            let actual = GridFeatures.rotate(grid, by: rotation)
            let meanError = zip(expected, actual).map { abs($0 - $1) }.reduce(0, +) / Float(expected.count)
            XCTAssertLessThan(meanError, 0.03, "\(rotation)")
        }
    }
}

final class SceneFeaturesRegionTests: XCTestCase {
    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private func wholePrint(_ image: CGImage) throws -> [Float] {
        let features = try XCTUnwrap(try SceneFeatures.features(of: image, rotatedBy: .none))
        return Array(features[0..<SceneFeatures.printDimension])
    }

    /// The "top half" region must be the top half of the frame Vision analysed *after* rotating it, or the model
    /// would learn from different regions than it is shown in the app.
    func testTopRegionIsTopOfTheRotatedFrame() throws {
        // Red and green on top, blue at the bottom: the two halves look nothing alike, in every orientation.
        let text = SceneGridTests.quadrants()
        let context = CIContext()
        for rotation in Rotation.allCases {
            let features = try XCTUnwrap(try SceneFeatures.features(of: text, rotatedBy: rotation))
            let d = SceneFeatures.printDimension
            let topRegion = Array(features[d..<(2 * d)]), bottomRegion = Array(features[(2 * d)..<(3 * d)])

            // Render the rotated frame and crop its halves by hand (Core Image is y-up: the top half has high y).
            let oriented = CIImage(cgImage: text).oriented(rotation.cgOrientation)
            let frame = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
            let w = frame.extent.width, h = frame.extent.height
            let top = try XCTUnwrap(context.createCGImage(frame, from: CGRect(x: 0, y: h / 2, width: w, height: h / 2)))
            let bottom = try XCTUnwrap(context.createCGImage(frame, from: CGRect(x: 0, y: 0, width: w, height: h / 2)))
            let topCrop = try wholePrint(top), bottomCrop = try wholePrint(bottom)

            XCTAssertGreaterThan(cosine(topRegion, topCrop), cosine(topRegion, bottomCrop), "\(rotation): top region")
            XCTAssertGreaterThan(cosine(bottomRegion, bottomCrop), cosine(bottomRegion, topCrop), "\(rotation): bottom region")
        }
    }
}
