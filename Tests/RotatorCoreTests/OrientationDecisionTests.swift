import XCTest
@testable import RotatorCore

final class RotationTests: XCTestCase {
    func testSnapping() {
        XCTAssertEqual(Rotation(degrees: 0), .none)
        XCTAssertEqual(Rotation(degrees: 89), .clockwise90)
        XCTAssertEqual(Rotation(degrees: -90), .clockwise270)
        XCTAssertEqual(Rotation(degrees: 450), .clockwise90)
        XCTAssertEqual(Rotation(degrees: 180), .rotate180)
    }

    func testComposition() {
        XCTAssertEqual(Rotation.clockwise90.followed(by: .clockwise90), .rotate180)
        XCTAssertEqual(Rotation.clockwise270.followed(by: .clockwise90), Rotation.none)
        for r in Rotation.allCases {
            XCTAssertEqual(r.followed(by: r.inverse), Rotation.none)
        }
    }
}

final class OrientationDeciderTests: XCTestCase {
    let decider = OrientationDecider()

    func testNoEvidenceIsInconclusive() {
        XCTAssertEqual(decider.decide([]).status, .inconclusive)
        let empty = DetectorEvidence(detector: "faces", weight: 1, uprightScores: [:])
        XCTAssertEqual(decider.decide([empty]).status, .inconclusive)
    }

    func testUprightFacesAreSkipped() {
        let e = DetectorEvidence(detector: "faces", weight: 1, uprightScores: [.none: 0.95])
        let d = decider.decide([e])
        XCTAssertEqual(d.status, .upright)
        XCTAssertEqual(d.rotation, Rotation.none)
    }

    func testSidewaysFacesProposeRotation() {
        let e = DetectorEvidence(detector: "faces", weight: 1, uprightScores: [.clockwise90: 0.9, .none: 0.05])
        let d = decider.decide([e])
        XCTAssertEqual(d.status, .needsRotation)
        XCTAssertEqual(d.rotation, .clockwise90)
        XCTAssertGreaterThan(d.confidence, 0.8)
    }

    func testEqualScoresEverywhereIsNotARotation() {
        // E.g. a face detector that cannot report roll finds the face in all four orientations.
        let all = Dictionary(uniqueKeysWithValues: Rotation.allCases.map { ($0, 0.9) })
        let d = decider.decide([DetectorEvidence(detector: "faces", weight: 1, uprightScores: all)])
        XCTAssertEqual(d.rotation, Rotation.none)
        XCTAssertEqual(d.confidence, 0)
    }

    func testConflictingEvidenceLowersConfidence() {
        let faces = DetectorEvidence(detector: "faces", weight: 1, uprightScores: [.clockwise270: 0.8])
        let text = DetectorEvidence(detector: "text", weight: 0.7, uprightScores: [.clockwise90: 0.9])
        let d = decider.decide([faces, text])
        XCTAssertEqual(d.rotation, .clockwise270)
        XCTAssertLessThan(d.confidence, 0.2)
        XCTAssertEqual(d.status, .inconclusive)
    }

    func testAgreeingDetectorsReinforce() {
        let faces = DetectorEvidence(detector: "faces", weight: 1, uprightScores: [.rotate180: 0.6])
        let body = DetectorEvidence(detector: "body", weight: 0.8, uprightScores: [.rotate180: 0.7])
        let d = decider.decide([faces, body])
        XCTAssertEqual(d.status, .needsRotation)
        XCTAssertEqual(d.rotation, .rotate180)
        XCTAssertEqual(d.confidence, 1, accuracy: 1e-9)
    }

    func testWeakEvidenceIsInconclusive() {
        let e = DetectorEvidence(detector: "text", weight: 0.7, uprightScores: [.clockwise90: 0.3])
        XCTAssertEqual(decider.decide([e]).status, .inconclusive)
    }
}

final class HelperTests: XCTestCase {
    func testNoisyOr() {
        XCTAssertEqual(noisyOr([]), 0)
        XCTAssertEqual(noisyOr([0.5, 0.5]), 0.75, accuracy: 1e-9)
        XCTAssertEqual(noisyOr([1.0, 0.2]), 1, accuracy: 1e-9)
    }

    func testUprightFactor() {
        XCTAssertEqual(uprightFactor(angleFromVertical: 0, toleranceDegrees: 30), 1, accuracy: 1e-9)
        XCTAssertEqual(uprightFactor(angleFromVertical: .pi / 2, toleranceDegrees: 30), 0)
        XCTAssertEqual(uprightFactor(angleFromVertical: 2 * .pi - 0.1, toleranceDegrees: 30), cos(0.1), accuracy: 1e-9)
        XCTAssertEqual(uprightFactor(angleFromVertical: .pi, toleranceDegrees: 30), 0)
    }
}
