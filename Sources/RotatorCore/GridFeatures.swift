import Foundation

/// Where things are in a photo: a coarse colour map plus where the horizontal and vertical edges are.
///
/// This is the classic cue for photo orientation (sky is bright and blue at the top, ground is darker and busier
/// at the bottom, horizons and buildings give long horizontal and vertical edges in typical places). It complements
/// Vision's feature print, which describes *what* a photo shows far better than *where*.
///
/// Input is a `side × side` RGB grid (row-major from the top-left, values `0...1`) of the photo as displayed.
public enum GridFeatures {
    /// Side of the RGB grid the photo is downsampled to.
    public static let side = 32
    /// Side of the coarse map the features are pooled into.
    public static let cells = 8
    /// Per cell: lightness, red–green, yellow–blue, horizontal-edge energy, vertical-edge energy.
    public static let dimension = cells * cells * 5

    /// The grid after rotating the photo clockwise by `rotation`. Quarter turns of a square grid are exact.
    public static func rotate(_ rgb: [Float], by rotation: Rotation) -> [Float] {
        let n = side
        precondition(rgb.count == n * n * 3)
        guard rotation != Rotation.none else { return rgb }
        var out = [Float](repeating: 0, count: rgb.count)
        for r in 0..<n {
            for c in 0..<n {
                // The source pixel that lands at (r, c).
                let (sr, sc): (Int, Int)
                switch rotation {
                case .clockwise90: (sr, sc) = (n - 1 - c, r)
                case .rotate180: (sr, sc) = (n - 1 - r, n - 1 - c)
                case .clockwise270: (sr, sc) = (c, n - 1 - r)
                case .none: (sr, sc) = (r, c)
                }
                for k in 0..<3 { out[(r * n + c) * 3 + k] = rgb[(sr * n + sc) * 3 + k] }
            }
        }
        return out
    }

    /// Features of a grid that is already in the orientation being judged.
    public static func features(_ rgb: [Float]) -> [Float] {
        let n = side, block = side / cells
        precondition(rgb.count == n * n * 3)
        var gray = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { gray[i] = (rgb[i * 3] + rgb[i * 3 + 1] + rgb[i * 3 + 2]) / 3 }

        var out = [Float](repeating: 0, count: dimension)
        let area = Float(block * block)
        for cr in 0..<cells {
            for cc in 0..<cells {
                var light: Float = 0, redGreen: Float = 0, yellowBlue: Float = 0, horizontal: Float = 0, vertical: Float = 0
                for r in (cr * block)..<((cr + 1) * block) {
                    for c in (cc * block)..<((cc + 1) * block) {
                        let i = r * n + c
                        let red = rgb[i * 3], green = rgb[i * 3 + 1], blue = rgb[i * 3 + 2]
                        light += gray[i]
                        redGreen += red - green
                        yellowBlue += (red + green) / 2 - blue
                        // A horizontal edge is a change going down; a vertical edge is a change going across.
                        if r + 1 < n { horizontal += abs(gray[i + n] - gray[i]) }
                        if c + 1 < n { vertical += abs(gray[i + 1] - gray[i]) }
                    }
                }
                let base = (cr * cells + cc) * 5
                out[base] = light / area
                out[base + 1] = redGreen / area
                out[base + 2] = yellowBlue / area
                out[base + 3] = horizontal / area
                out[base + 4] = vertical / area
            }
        }
        return out
    }

    /// Convenience: rotate, then compute features.
    public static func features(_ rgb: [Float], rotatedBy rotation: Rotation) -> [Float] {
        features(rotate(rgb, by: rotation))
    }
}
