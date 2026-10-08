import CoreGraphics
import RotatorCore

public enum SceneGrid {
    /// The photo averaged down to a `GridFeatures.side`² sRGB grid, row-major from the top-left, values `0...1`.
    public static func rgb(of image: CGImage) -> [Float]? {
        let n = GridFeatures.side
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = context.data else { return nil }
        // A bitmap context's first row in memory is the top of the image.
        let pixels = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var rgb = [Float](repeating: 0, count: n * n * 3)
        for i in 0..<(n * n) {
            for k in 0..<3 { rgb[i * 3 + k] = Float(pixels[i * 4 + k]) / 255 }
        }
        return rgb
    }
}
