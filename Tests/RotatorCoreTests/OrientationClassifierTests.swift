import XCTest
@testable import RotatorCore

final class OrientationClassifierTests: XCTestCase {
    /// Four noisy clusters in 16 dimensions, one per class.
    private func clusters(count: Int, seed: UInt64) -> [LabeledFeatures] {
        var rng = SplitMix64(seed: seed)
        let centers: [[Float]] = (0..<4).map { c in (0..<16).map { i in i % 4 == c ? 2 : 0 } }
        return (0..<count).map { k in
            let label = k % 4
            return LabeledFeatures(features: centers[label].map { $0 + rng.normal() * 0.5 }, label: label)
        }
    }

    func testTrainsSeparableClasses() {
        for hidden in [0, 16] {
            var trainer = OrientationTrainer()
            trainer.hiddenSize = hidden
            trainer.epochs = 30
            trainer.learningRate = 0.01
            let model = trainer.train(clusters(count: 800, seed: 1), validation: clusters(count: 200, seed: 2))
            XCTAssertGreaterThan(model.accuracy(on: clusters(count: 400, seed: 3)), 0.95, "hidden=\(hidden)")
        }
    }

    func testTrainingIsDeterministic() {
        var trainer = OrientationTrainer()
        trainer.hiddenSize = 8
        trainer.epochs = 3
        let data = clusters(count: 200, seed: 4)
        XCTAssertEqual(trainer.train(data), trainer.train(data))
    }

    func testSerialisationRoundTrip() throws {
        var trainer = OrientationTrainer()
        trainer.hiddenSize = 8
        trainer.epochs = 2
        let model = trainer.train(clusters(count: 100, seed: 5))
        XCTAssertEqual(try OrientationClassifier(data: model.encoded()), model)
        XCTAssertThrowsError(try OrientationClassifier(data: Data(model.encoded().dropLast(4))))
        XCTAssertThrowsError(try OrientationClassifier(data: Data([1, 2, 3, 4])))
    }

    func testProbabilitiesSumToOne() {
        var trainer = OrientationTrainer()
        trainer.epochs = 2
        let model = trainer.train(clusters(count: 100, seed: 6))
        let p = model.probabilities(clusters(count: 1, seed: 7)[0].features)
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testPassScoresAverageToTheRightCorrection() {
        // A photo needing 90° clockwise. In pass r the model sees a frame needing (90 - r), so a perfect model
        // outputs class (90 - r) / 90 in each pass.
        var total: [Rotation: Double] = [:]
        for pass in Rotation.allCases {
            let needed = Rotation.clockwise90.followed(by: pass.inverse)
            var p = [0.0, 0.0, 0.0, 0.0]
            p[needed.degrees / 90] = 1
            total.merge(OrientationClassifier.passScores(p, pass: pass)) { $0 + $1 }
        }
        XCTAssertEqual(total[.clockwise90] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(total[Rotation.none] ?? 0, 0, accuracy: 1e-9)
    }
}

final class OrientationPriorTests: XCTestCase {
    func testEqualPriorChangesNothing() {
        let scores: [Rotation: Double] = [.none: 0.1, .clockwise90: 0.6, .rotate180: 0.2, .clockwise270: 0.1]
        let applied = OrientationPrior.equal.apply(to: scores)
        for r in Rotation.allCases { XCTAssertEqual(applied[r]!, scores[r]!, accuracy: 1e-12) }
    }

    func testRealisticPriorNeedsMuchStrongerEvidenceForRareTurns() {
        let prior = OrientationPrior(upright: 0.90, sideways: 0.045, upsideDown: 0.01)
        // 60:20 for upside down is not enough against a 90% upright prior...
        let weak = prior.apply(to: [.none: 0.2, .rotate180: 0.6, .clockwise90: 0.1, .clockwise270: 0.1])
        XCTAssertGreaterThan(weak[Rotation.none]!, weak[.rotate180]!)
        // ...but overwhelming evidence still wins, and the total is kept.
        let strong = prior.apply(to: [.none: 0.005, .clockwise90: 0.99, .rotate180: 0.0025, .clockwise270: 0.0025])
        XCTAssertGreaterThan(strong[.clockwise90]!, strong[Rotation.none]!)
        XCTAssertEqual(strong.values.reduce(0, +), 1, accuracy: 1e-12)
    }
}
