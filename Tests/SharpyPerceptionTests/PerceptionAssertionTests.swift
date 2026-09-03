import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class PerceptionAssertionTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: rate) }
    func s(_ seconds: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(seconds * 1000), 1000)) }

    var asset: AssetRef {
        AssetRef(contentHash: "a", path: "/a", duration: t(600), frameRate: rate, hasVideo: true, hasAudio: true)
    }
    var solid: Basis { .measuredMaterial(ref: "x", detail: "y", confidence: .one) }

    /// A two-clip timeline whose join is a cut: clip 2 resumes at `resumeAt` in the source.
    func documentWithCut(resumeAt: TimeValue, firstClipFrames: Int64 = 60) throws -> Document {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .audio, name: "A1"))
        let id = log.head.assets.keys.first!
        let d = Decision(kind: .cut, at: .zero, basis: solid)
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(firstClipFrames)), start: .zero), decision: d))
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: resumeAt, end: resumeAt + t(60)), start: t(firstClipFrames)), decision: d))
        return log.head
    }

    /// "hello world" — 0.0–0.5 and 0.6–1.2 in the source.
    var transcript: Transcript {
        Transcript(asset: NodeID(contentOf: "a"),
                   words: [Word(index: 0, text: "hello", range: TimeRange(start: s(0), end: s(0.5)), confidence: Rational(95, 100)),
                           Word(index: 1, text: "world", range: TimeRange(start: s(0.6), end: s(1.2)), confidence: Rational(95, 100))],
                   engines: ["test"])
    }

    // MARK: cutting into speech

    func testACutInsideAWordBlocks() throws {
        // Resume at 0.9 s — squarely inside "world" (0.6–1.2).
        let doc = try documentWithCut(resumeAt: s(0.9))
        let p = PerceptionContext(transcript: transcript)
        let result = Verifier(assertions: [NoCutLandsInsideAWord(perception: p)]).verify(VerificationContext(document: doc))
        XCTAssertEqual(result.blocking.count, 1, "got \(result.failures.map(\.description))")
        XCTAssertTrue(result.blocking[0].detail.contains("world"))
        XCTAssertTrue(result.blocking[0].detail.contains("300 ms"))
    }

    func testACutInTheGapBetweenWordsPasses() throws {
        let doc = try documentWithCut(resumeAt: s(0.55))   // in the 0.5–0.6 gap
        let p = PerceptionContext(transcript: transcript)
        let result = Verifier(assertions: [NoCutLandsInsideAWord(perception: p)]).verify(VerificationContext(document: doc))
        XCTAssertTrue(result.failures.isEmpty, "got \(result.failures.map(\.description))")
    }

    func testACutJustInsideTheToleranceIsAllowed() throws {
        let doc = try documentWithCut(resumeAt: s(0.61))   // 10 ms into "world", inside a 20 ms tolerance
        let p = PerceptionContext(transcript: transcript)
        let result = Verifier(assertions: [NoCutLandsInsideAWord(perception: p)]).verify(VerificationContext(document: doc))
        XCTAssertTrue(result.failures.isEmpty, "a cut within tolerance of a boundary is clean")
    }

    /// The rule that keeps this honest: no transcript and a speech track means the check could not
    /// run, and it must say so rather than passing.
    func testAMissingTranscriptIsReportedNotPassed() throws {
        let doc = try documentWithCut(resumeAt: s(0.9))
        let result = Verifier(assertions: [NoCutLandsInsideAWord(perception: PerceptionContext())])
            .verify(VerificationContext(document: doc))
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].detail.contains("could not run"))
    }

    func testCuttingBesideDisputedSpeechHolds() throws {
        let disputed = Transcript(asset: NodeID(contentOf: "a"),
                                  words: [Word(index: 0, text: "didn't", range: TimeRange(start: s(0), end: s(0.5)), confidence: Rational(55, 100)),
                                          Word(index: 1, text: "make", range: TimeRange(start: s(0.6), end: s(1.2)), confidence: Rational(95, 100))],
                                  engines: ["a", "b"])
        let doc = try documentWithCut(resumeAt: s(0.55))
        let result = Verifier(assertions: [CutsRestOnConfidentWords(perception: PerceptionContext(transcript: disputed))])
            .verify(VerificationContext(document: doc))
        XCTAssertEqual(result.holds.count, 1)
        XCTAssertTrue(result.holds[0].detail.contains("didn't"))
        XCTAssertFalse(result.canRender, "a disputed word beside a cut should stop an unattended render")
    }

    // MARK: picture

    func makeVision(text: [(String, DetectedBox)], frames: Int = 4, width: Int = 1000, height: Int = 1000) -> VisionIndex {
        let observations = (0..<frames).map { i in
            FrameObservation(time: TimeValue(seconds: Rational(Int64(i))), faces: [], hands: [],
                             text: text.map { TextLine(text: $0.0, box: $0.1) })
        }
        return VisionIndex(asset: NodeID(contentOf: "a"), frames: observations, width: width, height: height)
    }

    func testTextOutsideTheSafeAreaWarns() throws {
        let doc = try documentWithCut(resumeAt: s(0.55))
        // Safe area at 90% of 1000×1000 leaves a 50 px margin; y = 10 is outside it.
        let unsafe = DetectedBox(x: 100, y: 10, width: 300, height: 40, confidence: 1)
        let p = PerceptionContext(vision: makeVision(text: [("TOO HIGH", unsafe)]))
        let result = Verifier(assertions: [TextIsInsideTheSafeArea(perception: p)]).verify(VerificationContext(document: doc))
        XCTAssertEqual(result.warnings.count, 1, "one distinct line, reported once")
        XCTAssertTrue(result.warnings[0].detail.contains("TOO HIGH"))
    }

    func testTextInsideTheSafeAreaPasses() throws {
        let doc = try documentWithCut(resumeAt: s(0.55))
        let safe = DetectedBox(x: 200, y: 200, width: 300, height: 40, confidence: 1)
        let p = PerceptionContext(vision: makeVision(text: [("FINE", safe)]))
        let result = Verifier(assertions: [TextIsInsideTheSafeArea(perception: p)]).verify(VerificationContext(document: doc))
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testTextTooBriefToReadWarns() throws {
        let doc = try documentWithCut(resumeAt: s(0.55))
        let box = DetectedBox(x: 200, y: 200, width: 300, height: 40, confidence: 1)
        // Sampled at 1 s intervals; one frame means ~1 s on screen. Six words need ~1.8 s.
        let index = VisionIndex(asset: NodeID(contentOf: "a"),
                                frames: [FrameObservation(time: .zero, faces: [], hands: [], text: [TextLine(text: "six whole words to read here", box: box)]),
                                         FrameObservation(time: TimeValue(seconds: Rational(1)), faces: [], hands: [], text: [])],
                                width: 1000, height: 1000)
        let result = Verifier(assertions: [TextIsOnScreenLongEnoughToRead(perception: PerceptionContext(vision: index))])
            .verify(VerificationContext(document: doc))
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].detail.contains("reading it needs"))
    }

    func testACutInsideAShotWarnsAsAPossibleJumpCut() throws {
        let doc = try documentWithCut(resumeAt: s(3.0))
        let shots = ShotIndex(asset: NodeID(contentOf: "a"),
                              shots: [Shot(index: 0, range: TimeRange(start: .zero, end: s(10)), boundaryScore: 0),
                                      Shot(index: 1, range: TimeRange(start: s(10), end: s(20)), boundaryScore: 0.5)],
                              threshold: 0.2, medianScore: 0.02)
        let result = Verifier(assertions: [CutsFallOnShotBoundaries(perception: PerceptionContext(shots: shots))])
            .verify(VerificationContext(document: doc))
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].detail.contains("jump cut"))
        XCTAssertTrue(result.canRender, "a jump cut is a legitimate device, so this warns")
    }

    func testACutOnAShotBoundaryPasses() throws {
        let doc = try documentWithCut(resumeAt: s(10.0))
        let shots = ShotIndex(asset: NodeID(contentOf: "a"),
                              shots: [Shot(index: 0, range: TimeRange(start: .zero, end: s(10)), boundaryScore: 0),
                                      Shot(index: 1, range: TimeRange(start: s(10), end: s(20)), boundaryScore: 0.5)],
                              threshold: 0.2, medianScore: 0.02)
        let result = Verifier(assertions: [CutsFallOnShotBoundaries(perception: PerceptionContext(shots: shots))])
            .verify(VerificationContext(document: doc))
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testWithPerceptionAddsToTheStandardSetAndComposesWithABrief() throws {
        let doc = try documentWithCut(resumeAt: s(0.55))
        let p = PerceptionContext(transcript: transcript)
        XCTAssertGreaterThan(Verifier.withPerception(p).assertions.count, Verifier.standard.assertions.count)
        let brief = Brief(audience: "a", intent: "keep it tight and clear", register: .grave, stakes: .routine)
        let both = Verifier.withPerception(p, brief: brief)
        XCTAssertGreaterThan(both.assertions.count, Verifier.forBrief(brief).assertions.count)
        // Structural checks from the standard set still run.
        let empty = Document(timeline: Timeline(name: "t", frameRate: rate))
        XCTAssertTrue(both.verify(VerificationContext(document: empty)).blocking.contains { $0.assertion.contains("something on it") })
        _ = doc
    }
}
