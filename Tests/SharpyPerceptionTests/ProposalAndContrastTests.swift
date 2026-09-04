// Tier 4: a model may cause a measurement, never a verdict. And the measurement it causes has to
// be a real one — a compiler that accepts a name with nothing behind it is worse than no compiler.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class ProposalAndContrastTests: XCTestCase {
    func s(_ x: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(x * 100), 100)) }

    func vision(text: [String] = ["caption"], faces: Int = 1, at: Double = 0) -> VisionIndex {
        VisionIndex(asset: NodeID(contentOf: "a"),
                    frames: [FrameObservation(
                        time: s(at),
                        faces: (0..<faces).map { _ in DetectedBox(x: 10, y: 10, width: 20, height: 20, confidence: 0.9) },
                        hands: [],
                        text: text.map { TextLine(text: $0, box: DetectedBox(x: 0, y: 50, width: 100, height: 10, confidence: 0.9)) })],
                    width: 100, height: 100)
    }

    func context(_ v: VisionIndex?) -> PerceptionContext {
        PerceptionContext(vision: v)
    }

    // MARK: the compiler

    /// Every name the compiler accepts must have a measurement behind it. Accepting a name with
    /// nothing behind it would let proposals compile while nothing ran — the failure mode where
    /// the report looks healthiest precisely when it is emptiest.
    func testEveryKnownKindIsSpelledOutAndSmall() {
        XCTAssertEqual(CheckCompiler.known, ["textContrast", "textSafeArea", "textDuration", "subjectInFrame"])
    }

    func testAnUnknownKindIsRejectedAndSaysWhatIsAvailable() {
        let compiler = CheckCompiler(perception: context(vision()))
        let result = compiler.compile(ProposedCheck(kind: "vibeCheck", at: s(0), note: "feels off"))
        guard case .rejected(let reason) = result.outcome else { return XCTFail("must not compile") }
        XCTAssertTrue(reason.contains("no measurement named"))
        XCTAssertTrue(reason.contains("textContrast"), "a rejection should say what IS measurable")
    }

    /// The model naming a verdict must not make it one. This is the whole rule.
    func testAModelCannotSmuggleInAVerdictByNamingIt() {
        let compiler = CheckCompiler(perception: context(vision()))
        for smuggled in ["thisEditIsBad", "looksUnprofessional", "block", "approve"] {
            XCTAssertFalse(compiler.compile(ProposedCheck(kind: smuggled)).outcome.isCompiled,
                           "\(smuggled) must not compile")
        }
    }

    func testAProposalWithoutAVisionPassIsRejectedNotSilentlyPassed() {
        let compiler = CheckCompiler(perception: context(nil))
        let result = compiler.compile(ProposedCheck(kind: "textContrast", at: s(0)))
        guard case .rejected(let reason) = result.outcome else { return XCTFail("must not compile") }
        XCTAssertTrue(reason.contains("Vision pass"))
    }

    /// A proposal about a moment where the thing it describes does not exist is a rejection, not a
    /// check that trivially passes.
    func testAProposalAboutNothingIsRejected() {
        let compiler = CheckCompiler(perception: context(vision(text: [])))
        let result = compiler.compile(ProposedCheck(kind: "textContrast", at: s(0), note: "hard to read"))
        guard case .rejected(let reason) = result.outcome else { return XCTFail("must not compile") }
        XCTAssertTrue(reason.contains("no on-screen text"))
    }

    func testAProposalTooFarFromAnyObservationIsRejected() {
        let compiler = CheckCompiler(perception: context(vision(at: 0)))
        let result = compiler.compile(ProposedCheck(kind: "textContrast", at: s(30)))
        guard case .rejected(let reason) = result.outcome else { return XCTFail("must not compile") }
        XCTAssertTrue(reason.contains("too far"))
    }

    func testAGoodProposalCompilesAndNamesItsInputs() {
        let compiler = CheckCompiler(perception: context(vision()))
        let result = compiler.compile(ProposedCheck(kind: "textContrast", at: s(0)))
        guard case .compiled(let check, let detail) = result.outcome else { return XCTFail("should compile") }
        XCTAssertEqual(check, "textContrast")
        XCTAssertTrue(detail.contains("1 text line"))
    }

    /// The compile rate is the number M4 wants: a model whose proposals mostly fail to compile is
    /// describing things this system cannot check, which is a roadmap rather than a fault.
    func testCompileRateIsReported() {
        let compiler = CheckCompiler(perception: context(vision()))
        let report = ProposalReport(results: compiler.compile([
            ProposedCheck(kind: "textContrast", at: s(0)),
            ProposedCheck(kind: "subjectInFrame", at: s(0)),
            ProposedCheck(kind: "vibeCheck", at: s(0)),
            ProposedCheck(kind: "isItGood", at: s(0)),
        ]))
        XCTAssertEqual(report.compileRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.rejected.count, 2)
        XCTAssertTrue(report.summary.contains("2 of 4"))
    }

    // MARK: the contrast measurement itself

    /// Against the values WCAG publishes: black on white is 21:1, and white on white is 1:1.
    func testContrastRatioMatchesTheStandard() {
        let white = TextContrastMeter.relativeLuminance(r: 1, g: 1, b: 1)
        let black = TextContrastMeter.relativeLuminance(r: 0, g: 0, b: 0)
        XCTAssertEqual(white, 1.0, accuracy: 0.0001)
        XCTAssertEqual(black, 0.0, accuracy: 0.0001)
        XCTAssertEqual(TextContrastMeter.ratio(lighter: white, darker: black), 21.0, accuracy: 0.01,
                       "WCAG's maximum is exactly 21:1")
        XCTAssertEqual(TextContrastMeter.ratio(lighter: white, darker: white), 1.0, accuracy: 0.001)
    }

    /// Green carries most of perceived brightness, so a channel average would call yellow-on-white
    /// high contrast when a reader can barely see it. This pins the weighting.
    func testLuminanceIsWeightedNotAveraged() {
        let yellow = TextContrastMeter.relativeLuminance(r: 1, g: 1, b: 0)
        let blue = TextContrastMeter.relativeLuminance(r: 0, g: 0, b: 1)
        XCTAssertGreaterThan(yellow, 0.9, "yellow is nearly as bright as white")
        XCTAssertLessThan(blue, 0.1, "blue is nearly as dark as black")
        let onWhite = TextContrastMeter.ratio(lighter: 1.0, darker: yellow)
        XCTAssertLessThan(onWhite, 1.2, "yellow on white is unreadable and must measure that way")
    }

    func testTheAssertionWarnsRatherThanBlocks() {
        let low = TextContrastReading(time: s(1), text: "buy now", ratio: 1.4,
                                      lighterLuminance: 0.9, darkerLuminance: 0.8)
        let assertion = TextHasEnoughContrast(readings: [low])
        XCTAssertEqual(assertion.mode, .warn,
                       "the method approximates a web standard; blocking would claim more than it knows")
        XCTAssertEqual(assertion.category, .legibility)
        let failures = assertion.evaluate(VerificationContext(document: Document(timeline: Timeline(name: "t", frameRate: .r30))))
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].detail.contains("1.4:1"))
    }

    func testGoodContrastProducesNoFailure() {
        let fine = TextContrastReading(time: s(1), text: "readable", ratio: 12.0,
                                       lighterLuminance: 1.0, darkerLuminance: 0.02)
        XCTAssertTrue(fine.meetsLargeTextAA)
        XCTAssertTrue(fine.meetsNormalTextAA)
        let failures = TextHasEnoughContrast(readings: [fine])
            .evaluate(VerificationContext(document: Document(timeline: Timeline(name: "t", frameRate: .r30))))
        XCTAssertTrue(failures.isEmpty)
    }
}
