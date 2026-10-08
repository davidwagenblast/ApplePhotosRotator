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

