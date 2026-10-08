import XCTest
@testable import RotatorCore

final class GridFeaturesTests: XCTestCase {
    private let n = GridFeatures.side

    private func randomGrid(seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<(n * n * 3)).map { _ in Float(Double.random(in: 0...1, using: &rng)) }
    }

    func testRotationsCompose() {
        let grid = randomGrid(seed: 1)
        for a in Rotation.allCases {
            for b in Rotation.allCases {
                XCTAssertEqual(
                    GridFeatures.rotate(GridFeatures.rotate(grid, by: a), by: b),
                    GridFeatures.rotate(grid, by: a.followed(by: b)), "\(a) then \(b)"
                )
            }
        }
    }

    func testClockwiseQuarterTurnMovesTopRowToRightColumn() {
        var grid = [Float](repeating: 0, count: n * n * 3)
        for c in 0..<n { grid[c * 3] = 1 } // top row red
        let turned = GridFeatures.rotate(grid, by: .clockwise90)
        for r in 0..<n {
            XCTAssertEqual(turned[(r * n + n - 1) * 3], 1, "right column, row \(r)")
            XCTAssertEqual(turned[(r * n) * 3], 0, "left column, row \(r)")
        }
    }

    func testBrightTopShowsInFeatures() {
        // Sky-like top half (bright, blue), ground-like bottom half (dark).
        var grid = [Float](repeating: 0.2, count: n * n * 3)
        for r in 0..<(n / 2) { for c in 0..<n { grid[(r * n + c) * 3 + 2] = 0.9; grid[(r * n + c) * 3] = 0.6; grid[(r * n + c) * 3 + 1] = 0.7 } }
        let upright = GridFeatures.features(grid)
        let upsideDown = GridFeatures.features(grid, rotatedBy: .rotate180)
        XCTAssertEqual(upright.count, GridFeatures.dimension)
        // Lightness of the top-left cell.
        XCTAssertGreaterThan(upright[0], upsideDown[0])
        // The horizon gives horizontal-edge energy in row 3 of cells, not vertical-edge energy.
        let horizonCell = (3 * GridFeatures.cells + 0) * 5
        XCTAssertGreaterThan(upright[horizonCell + 3], upright[horizonCell + 4])
        let sideways = GridFeatures.features(grid, rotatedBy: .clockwise90)
        let sidewaysHorizonCell = (0 * GridFeatures.cells + 4) * 5
        XCTAssertGreaterThan(sideways[sidewaysHorizonCell + 4], sideways[sidewaysHorizonCell + 3])
    }
}
