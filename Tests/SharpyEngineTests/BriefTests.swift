import XCTest
@testable import SharpyEngine

final class BriefTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: rate) }
    var asset: AssetRef {
        AssetRef(contentHash: "a", path: "/a", duration: t(300), frameRate: rate, hasVideo: true, hasAudio: false)
    }

    /// A document with one clip, plus whatever extra decisions a test wants recorded.
    func document(extra: [Decision] = []) throws -> Document {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(100)), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: .measuredMaterial(ref: "x", detail: "y", confidence: .one))))
        for d in extra { try log.append(.recordDecision(d)) }
        return log.head
    }

    var tribute: Brief {
        Brief(audience: "the family", intent: "remember him without decoration",
              register: .grave, stakes: .high)
    }

    // MARK: the hole this closes

    /// The load-bearing test. A whip transition in a memorial is not a matter of taste, and with a
    /// register in the brief it becomes an assertion violation with a timecode rather than
    /// something only a human viewer would ever notice.
    func testAComedicDeviceInAGravePieceBlocks() throws {
        let whip = Decision(kind: .transition, at: t(60), params: ["device": "whip"],
                            basis: .craftRule(rule: "transition on the beat", why: "energy"))
        let doc = try document(extra: [whip])
        let result = Verifier.forBrief(tribute).verify(VerificationContext(document: doc))
        let failure = result.blocking.first { $0.assertion.contains("register") }
        XCTAssertNotNil(failure, "a whip in a grave piece must block; got \(result.failures.map(\.description))")
        XCTAssertEqual(failure?.at, t(60), "and it must say where")
        XCTAssertTrue(failure!.detail.contains("grave"))
    }

    func testTheSameDeviceIsFineInAPlayfulPiece() throws {
        let whip = Decision(kind: .transition, at: t(60), params: ["device": "whip"],
                            basis: .craftRule(rule: "transition on the beat", why: "energy"))
        let doc = try document(extra: [whip])
        let playful = Brief(audience: "feed", intent: "make them laugh in ten seconds",
                            register: .playful, stakes: .routine)
        let result = Verifier.forBrief(playful).verify(VerificationContext(document: doc))
        XCTAssertFalse(result.blocking.contains { $0.assertion.contains("register") },
                       "the device is only wrong relative to a register")
    }

    func testExplicitProhibitionsAddToTheRegistersOwn() throws {
        let dissolve = Decision(kind: .transition, at: t(30), params: ["device": "dissolve"],
                                basis: .clientRule(rule: "soften the join"))
        let doc = try document(extra: [dissolve])
        let plain = Brief(audience: "team", intent: "explain the change clearly",
                          register: .neutral, stakes: .routine)
        XCTAssertTrue(Verifier.forBrief(plain).verify(VerificationContext(document: doc)).blocking.isEmpty)

        let noDissolves = Brief(audience: "team", intent: "explain the change clearly",
                                register: .neutral, stakes: .routine, prohibitedDevices: [.dissolve])
        let result = Verifier.forBrief(noDissolves).verify(VerificationContext(document: doc))
        XCTAssertTrue(result.blocking.contains { $0.detail.contains("dissolve") })
    }

    // MARK: stakes

    func testStakesScaleTheBarForShippingUnattended() throws {
        let shaky = Decision(kind: .cut, at: t(10), basis: .measuredMaterial(ref: "p", detail: "d", confidence: Rational(90, 100)))
        let doc = try document(extra: [shaky])

        let routine = Brief(audience: "a", intent: "post it today", register: .neutral, stakes: .routine)
        XCTAssertTrue(Verifier.forBrief(routine).verify(VerificationContext(document: doc)).holds.isEmpty,
                      "0.90 clears the routine bar of 0.70")

        let high = Brief(audience: "a", intent: "this one has to be right", register: .neutral, stakes: .high)
        XCTAssertFalse(Verifier.forBrief(high).verify(VerificationContext(document: doc)).holds.isEmpty,
                       "0.90 does not clear the high bar of 0.95")
    }

    /// Irreversible means always reviewed — a setting, not a hope.
    func testIrreversibleStakesAlwaysHold() throws {
        let certain = Decision(kind: .cut, at: t(10), basis: .clientRule(rule: "the client asked for this cut"))
        let doc = try document(extra: [certain])
        XCTAssertEqual(certain.basis.confidence, .one, "a client rule carries full confidence")
        let brief = Brief(audience: "a", intent: "there is no taking this back", register: .earnest, stakes: .irreversible)
        let result = Verifier.forBrief(brief).verify(VerificationContext(document: doc))
        XCTAssertFalse(result.holds.isEmpty, "nothing clears the irreversible bar, by design")
        XCTAssertFalse(result.canRender)
    }

    // MARK: compilation

    func testABriefThatStatesSomethingCheckableCompiles() {
        let c = tribute.compile()
        XCTAssertTrue(c.canBeContradicted)
        XCTAssertTrue(c.checkable.contains { $0.contains("grave") && $0.contains("whip") })
        XCTAssertTrue(c.checkable.contains { $0.contains("high") })
    }

    func testUncheckableHouseRulesAreSurfacedNotDropped() {
        let brief = Brief(audience: "a", intent: "make it feel expensive", register: .neutral, stakes: .routine,
                          houseRules: ["never use a whip transition", "make it feel more premium"])
        let c = brief.compile()
        XCTAssertTrue(c.checkable.contains { $0.contains("whip") }, "a rule naming a device compiles")
        XCTAssertTrue(c.uncheckable.contains("make it feel more premium"), "a vague rule is surfaced, not silently ignored")
    }

    func testAVagueBriefWarnsThatItCannotBeContradicted() throws {
        let doc = try document()
        let vague = Brief(audience: "everyone", intent: "good", register: .neutral, stakes: .routine,
                          houseRules: ["make it pop"])
        let result = Verifier.forBrief(vague).verify(VerificationContext(document: doc))
        XCTAssertTrue(result.warnings.contains { $0.detail.contains("only advice") && $0.detail.contains("make it pop") })
        XCTAssertTrue(result.warnings.contains { $0.detail.contains("too short to mean anything") })
        XCTAssertTrue(result.canRender, "an unfalsifiable brief is a process problem, not a broken render")
    }

    func testARequiredDeviceThatNeverAppearsWarns() throws {
        let doc = try document()
        let brief = Brief(audience: "a", intent: "open on the strongest line", register: .neutral, stakes: .routine,
                          requiredDevices: [.jumpCut])
        let result = Verifier.forBrief(brief).verify(VerificationContext(document: doc))
        XCTAssertTrue(result.warnings.contains { $0.detail.contains("jumpCut") && $0.detail.contains("never uses it") })
    }

    func testBriefAssertionsAddToTheStandardSetRatherThanReplacingIt() throws {
        let doc = try document()
        let withBrief = Verifier.forBrief(tribute)
        XCTAssertGreaterThan(withBrief.assertions.count, Verifier.standard.assertions.count)
        // The standard structural checks still run.
        let empty = Document(timeline: Timeline(name: "t", frameRate: rate))
        XCTAssertTrue(withBrief.verify(VerificationContext(document: empty)).blocking.contains { $0.assertion.contains("something on it") })
        _ = doc
    }

    func testDeviceIsReadFromTheDecisionRecord() {
        let d = Decision(kind: .transition, at: .zero, params: ["device": "whip"], basis: .clientRule(rule: "x"))
        XCTAssertEqual(d.device, .whip)
        let plain = Decision(kind: .cut, at: .zero, basis: .clientRule(rule: "x"))
        XCTAssertNil(plain.device)
        let unknown = Decision(kind: .cut, at: .zero, params: ["device": "kenBurns"], basis: .clientRule(rule: "x"))
        XCTAssertNil(unknown.device, "an unrecognised device name must not silently match something")
    }
}
