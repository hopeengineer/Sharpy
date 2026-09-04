// The scene layer's job is to be overridable. These pin that.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class SceneIndexTests: XCTestCase {
    func s(_ x: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(x * 100), 100)) }

    func frame(_ t: Double, faces: Int) -> FrameObservation {
        FrameObservation(time: s(t),
                         faces: (0..<faces).map { _ in
                             DetectedBox(x: 0, y: 0, width: 100, height: 100, confidence: 0.9)
                         },
                         hands: [], text: [])
    }

    func obs(_ t: Double, _ shot: ShotSize, faces: Int?) -> SceneObservation {
        let vision = faces.map { frame(t, faces: $0) }
        let (standing, reason) = SceneCrossCheck.standing(shot: shot, vision: vision)
        return SceneObservation(time: s(t), shot: shot, activity: "talking", setting: "room",
                                standing: standing, reason: reason)
    }

    /// The whole point: a model's claim loses to a measurement.
    func testVisionContradictsTheModelAndWins() {
        let claimedCard = obs(1, .card, faces: 1)
        XCTAssertEqual(claimedCard.standing, .contradicted)
        XCTAssertFalse(claimedCard.standing.usable)
        XCTAssertNil(claimedCard.basis(evidence: ["vision/1"]),
                     "a contradicted claim supplies no basis, so it cannot reach a render")

        let claimedCloseUp = obs(2, .closeUp, faces: 0)
        XCTAssertEqual(claimedCloseUp.standing, .contradicted)
    }

    func testCorroboratedClaimsSupplyOnlyTheWeakestBasis() {
        let o = obs(1, .closeUp, faces: 1)
        XCTAssertEqual(o.standing, .corroborated)
        guard case .structuralInference(_, let confidence)? = o.basis(evidence: ["vision/1"]) else {
            return XCTFail("a scene claim must be a structural inference and nothing stronger")
        }
        XCTAssertEqual(confidence, Rational(7, 10))
        // Rank 7 is the bottom of the hierarchy — below every measured fact.
        XCTAssertEqual(o.basis(evidence: [])?.rank, 7)
    }

    /// A wide shot legitimately has no detectable face, so Vision must not be allowed to "refute"
    /// it. Turning an unverifiable claim into a contradiction would silently delete real footage.
    func testUnverifiableClaimsAreUncheckedNotContradicted() {
        XCTAssertEqual(obs(1, .wide, faces: 0).standing, .unchecked)
        XCTAssertEqual(obs(2, .medium, faces: 0).standing, .unchecked)
        XCTAssertEqual(obs(3, .card, faces: nil).standing, .unchecked,
                       "no Vision observation means no verdict, not a bad verdict")
    }

    /// "Keep the wide shots" must not be extended by a frame Vision rejected.
    func testContradictedFramesDoNotExtendARun() {
        let index = SceneIndex(asset: NodeID(contentOf: "a"), observations: [
            obs(1, .wide, faces: 0),
            obs(2, .wide, faces: 0),
            obs(3, .closeUp, faces: 0),   // contradicted
            obs(4, .wide, faces: 0),
        ], model: "test")
        let runs = index.runs(of: .wide, tolerance: s(1))
        XCTAssertEqual(runs.count, 2, "the rejected frame must break the run, not bridge it")
        XCTAssertEqual(index.contradicted.count, 1)
    }

    func testCorroborationRateIsReportedSoABadModelIsVisible() {
        let index = SceneIndex(asset: NodeID(contentOf: "a"), observations: [
            obs(1, .closeUp, faces: 1), obs(2, .card, faces: 0),
            obs(3, .card, faces: 1), obs(4, .wide, faces: 0),
        ], model: "test")
        XCTAssertEqual(index.corroborationRate, 0.5, accuracy: 0.001)
    }

    /// The cross-check's blind spot, pinned. `other` and `wide` assert nothing Vision can refute,
    /// so a model that abstains everywhere posts zero contradictions and looks perfect. The
    /// abstention rate is what makes that visible, and SceneIndexer refuses an index above 50%.
    func testAbstainingEverywhereLooksPerfectUntilYouCountAbstentions() {
        let dodger = SceneIndex(asset: NodeID(contentOf: "a"), observations: [
            obs(1, .other, faces: 1), obs(2, .other, faces: 0),
            obs(3, .other, faces: 1), obs(4, .other, faces: 0),
        ], model: "test")
        XCTAssertTrue(dodger.contradicted.isEmpty, "abstention is never contradicted — that is the hole")
        XCTAssertEqual(dodger.corroborationRate, 0, accuracy: 0.001)
        XCTAssertEqual(dodger.abstentionRate, 1.0, accuracy: 0.001, "and this is what closes it")
    }

    /// Abstaining on a genuinely ambiguous frame is correct and must not be punished: the reel has
    /// a near-blank frame at 40 s where "other" is the right answer.
    func testOccasionalAbstentionIsFine() {
        let index = SceneIndex(asset: NodeID(contentOf: "a"), observations: [
            obs(1, .medium, faces: 1), obs(2, .medium, faces: 1),
            obs(3, .other, faces: 0), obs(4, .card, faces: 0),
        ], model: "test")
        XCTAssertEqual(index.abstentionRate, 0.25, accuracy: 0.001)
        XCTAssertTrue(index.contradicted.isEmpty)
    }
}
