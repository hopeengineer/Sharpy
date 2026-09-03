import XCTest
@testable import SharpyEngine

final class TranscriptTests: XCTestCase {
    /// "so um the thing" — word 1 is a filler, with a deliberate long pause after word 2.
    ///  0 "so"    0.00–0.30
    ///  1 "um"    0.40–0.60      (0.10 gap either side)
    ///  2 "the"   0.70–0.90
    ///  3 "thing" 2.00–2.40      (1.10 s pause before it)
    static func t(_ ms: Int64) -> TimeValue { TimeValue(seconds: Rational(ms, 1000)) }
    static func w(_ i: Int, _ text: String, _ a: Int64, _ b: Int64, conf: Int = 90) -> Word {
        Word(index: i, text: text, range: TimeRange(start: t(a), end: t(b)), confidence: Rational(Int64(conf), 100))
    }
    var sample: Transcript {
        Transcript(asset: NodeID(contentOf: "x"),
                   words: [Self.w(0, "so", 0, 300), Self.w(1, "um", 400, 600),
                           Self.w(2, "the", 700, 900), Self.w(3, "thing.", 2000, 2400)],
                   engines: ["test"])
    }

    func testAddressingAndLookup() {
        let t = sample
        XCTAssertEqual(t.text, "so um the thing.")
        XCTAssertEqual(t.word(at: Self.t(500))?.text, "um")
        XCTAssertNil(t.word(at: Self.t(350)), "a gap belongs to no word")
        XCTAssertEqual(t.words(in: TimeRange(start: Self.t(250), end: Self.t(750))).map(\.index), [0, 1, 2])
        XCTAssertEqual(t.fillers.map(\.index), [1])
    }

    func testPausesAreMeasuredNotGuessed() {
        let t = sample
        XCTAssertEqual(t.pauses(longerThan: Self.t(50)).map(\.afterWord), [0, 1, 2])
        let long = t.pauses(longerThan: Self.t(500))
        XCTAssertEqual(long.count, 1)
        XCTAssertEqual(long[0].afterWord, 2)
        XCTAssertEqual(long[0].duration, Self.t(1100))
    }

    func testSegmentsSplitOnPunctuationAndLongGaps() {
        let segs = sample.segments(pauseSplit: Self.t(600))
        XCTAssertEqual(segs.count, 2, "the 1.1 s gap before 'thing' splits the segment")
        XCTAssertEqual(segs[0].firstWord, 0); XCTAssertEqual(segs[0].text, "so um the")
        XCTAssertEqual(segs[1].firstWord, 3); XCTAssertEqual(segs[1].text, "thing.")
    }

    func testSpanCoversWordsWithPadding() {
        let s = sample.span(1...2, pad: Self.t(50))!
        XCTAssertEqual(s.start, Self.t(350)); XCTAssertEqual(s.end, Self.t(950))
        // Padding never runs before zero.
        XCTAssertEqual(sample.span(0...0, pad: Self.t(500))!.start, .zero)
    }

    func testLowConfidenceIsReported() {
        let t = Transcript(asset: NodeID(contentOf: "x"),
                           words: [Self.w(0, "sure", 0, 100, conf: 95), Self.w(1, "maybe", 100, 200, conf: 40)],
                           engines: ["test"])
        XCTAssertEqual(t.lowConfidence(below: Rational(7, 10)).map(\.text), ["maybe"])
    }

    /// Alignment must be by sequence, not by time. Measured on real narration, WhisperKit and
    /// Apple place the same words hundreds of milliseconds apart; a time-overlap merge marked
    /// 197 of 263 words disputed — 75 % false disagreement, which would hold every render.
    func testOffsetTimingsDoNotCauseFalseDisagreement() {
        func w(_ i: Int, _ text: String, _ a: Double, _ b: Double) -> Word {
            Word(index: i, text: text,
                 range: TimeRange(start: TimeValue(seconds: Rational(Int64(a * 1000), 1000)),
                                  end: TimeValue(seconds: Rational(Int64(b * 1000), 1000))),
                 confidence: Rational(9, 10))
        }
        let primary = Transcript(asset: NodeID(contentOf: "x"),
                                 words: [w(0, "this", 0.00, 0.48), w(1, "morning", 0.48, 1.02), w(2, "my", 1.02, 1.14)],
                                 engines: ["whisper"])
        // The same words, every timing shifted by a third of a second.
        let secondary = Transcript(asset: NodeID(contentOf: "x"),
                                   words: [w(0, "this", 0.34, 0.70), w(1, "morning", 0.96, 1.40), w(2, "my", 1.40, 1.60)],
                                   engines: ["apple"])
        let merged = TranscriptMerge.agree(primary: primary, secondary: secondary)
        for word in merged.words {
            XCTAssertGreaterThan(word.confidence, Rational(9, 10),
                                 "\"\(word.text)\" is identical in both engines and must agree despite the offset")
        }
    }

    func testAlignmentSurvivesAnInsertionInTheMiddle() {
        func w(_ i: Int, _ text: String, _ a: Double) -> Word {
            Word(index: i, text: text,
                 range: TimeRange(start: TimeValue(seconds: Rational(Int64(a * 100), 100)),
                                  duration: TimeValue(seconds: Rational(10, 100))),
                 confidence: Rational(9, 10))
        }
        let primary = Transcript(asset: NodeID(contentOf: "x"),
                                 words: [w(0, "get", 0), w(1, "my", 1), w(2, "voice", 2), w(3, "closer", 3)],
                                 engines: ["whisper"])
        // Secondary heard an extra word and got one wrong.
        let secondary = Transcript(asset: NodeID(contentOf: "x"),
                                   words: [w(0, "get", 0), w(1, "my", 1), w(2, "own", 2), w(3, "voice", 3), w(4, "close", 4)],
                                   engines: ["apple"])
        let merged = TranscriptMerge.agree(primary: primary, secondary: secondary)
        XCTAssertGreaterThan(merged.words[0].confidence, Rational(9, 10), "get")
        XCTAssertGreaterThan(merged.words[1].confidence, Rational(9, 10), "my")
        XCTAssertGreaterThan(merged.words[2].confidence, Rational(9, 10), "voice survives the inserted word")
        XCTAssertLessThan(merged.words[3].confidence, Rational(7, 10), "closer vs close is a real disagreement")
    }

    /// The measured finding this encodes: errors live where two engines disagree.
    func testAgreementRaisesConfidenceAndDisagreementLowersIt() {
        let primary = Transcript(asset: NodeID(contentOf: "x"),
                                 words: [Self.w(0, "didn't", 0, 300), Self.w(1, "make", 300, 600)],
                                 engines: ["whisper-turbo"])
        let secondary = Transcript(asset: NodeID(contentOf: "x"),
                                   words: [Self.w(0, "did", 0, 300), Self.w(1, "make", 300, 600)],
                                   engines: ["parakeet"])
        let merged = TranscriptMerge.agree(primary: primary, secondary: secondary)
        XCTAssertLessThan(merged.words[0].confidence, Rational(7, 10), "engines disagree on 'didn\'t' vs 'did'")
        XCTAssertGreaterThan(merged.words[1].confidence, Rational(9, 10), "engines agree on 'make'")
        XCTAssertEqual(merged.words[1].sources, ["whisper-turbo", "parakeet"])
        XCTAssertEqual(merged.text, primary.text, "the primary engine still supplies the words")
    }
}

final class WordEditTests: XCTestCase {
    typealias T = TranscriptTests
    var sample: Transcript { TranscriptTests().sample }

    func testRemovingAFillerClosesTheDoubleGap() {
        let plan = WordEdit.plan(removing: [1], from: sample, aggressiveness: .tight)
        XCTAssertEqual(plan.ranges.count, 1)
        // tight keeps none of the leading pause and runs to the next word: 0.30 → 0.70
        XCTAssertEqual(plan.ranges[0].start, T.t(300))
        XCTAssertEqual(plan.ranges[0].end, T.t(700))
        XCTAssertEqual(plan.removedWords.map(\.text), ["um"])
        XCTAssertEqual(plan.removed, T.t(400), "the word plus both halves of its surrounding silence")
    }

    func testAggressivenessControlsHowMuchPauseSurvives() {
        let tight = WordEdit.plan(removing: [1], from: sample, aggressiveness: .tight).removed
        let balanced = WordEdit.plan(removing: [1], from: sample, aggressiveness: .balanced).removed
        let loose = WordEdit.plan(removing: [1], from: sample, aggressiveness: .loose).removed
        XCTAssertGreaterThan(tight.seconds, balanced.seconds, "tight removes more")
        XCTAssertGreaterThan(balanced.seconds, loose.seconds, "loose leaves more room")
    }

    func testConsecutiveWordsMergeIntoOneCut() {
        let plan = WordEdit.plan(removing: [1, 2], from: sample, aggressiveness: .tight)
        XCTAssertEqual(plan.ranges.count, 1, "adjacent removals are one cut, not two")
        XCTAssertEqual(plan.ranges[0].start, T.t(300))
        XCTAssertEqual(plan.ranges[0].end, T.t(2000))
    }

    func testUnknownIndicesAreReportedNotIgnored() {
        let plan = WordEdit.plan(removing: [1, 99], from: sample)
        XCTAssertEqual(plan.unknownIndices, [99])
        XCTAssertEqual(plan.removedWords.map(\.index), [1])
    }

    func testTighteningPausesRemovesOnlyDeadAir() {
        let plan = WordEdit.planTighteningPauses(longerThan: T.t(300), in: sample)
        XCTAssertTrue(plan.removedWords.isEmpty, "no speech is removed")
        XCTAssertEqual(plan.ranges.count, 1, "only the 1.1 s gap exceeds 0.3 s")
        XCTAssertEqual(plan.ranges[0].start, T.t(1200), "0.9 s word end + 0.3 s kept")
        XCTAssertEqual(plan.ranges[0].end, T.t(2000))
    }

    func testPlanBecomesRippleDeletesInReverseOrder() throws {
        let rate = FrameRate.r30
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        let asset = AssetRef(contentHash: "a", path: "/a", duration: TimeValue(seconds: Rational(10)),
                             frameRate: rate, hasVideo: false, hasAudio: true)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .audio, name: "A1"))
        let id = log.head.assets.keys.first!
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, duration: TimeValue(seconds: Rational(10))), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: .clientRule(rule: "place"))))

        let plan = WordEdit.plan(removing: [1], from: sample, aggressiveness: .tight)
        let basis = Basis.measuredMaterial(ref: "word 1", detail: "filler 'um'", confidence: Rational(9, 10))
        let commands = try log.head.commands(applying: plan, toTrack: 0, basis: basis)
        XCTAssertEqual(commands.count, 1)
        for c in commands { try log.append(c) }
        XCTAssertEqual(log.head.timeline.duration, TimeValue(seconds: Rational(10)) - T.t(400))
        // Every decision the plan produced carries the basis it was given.
        for id in log.head.decisionOrder.suffix(1) {
            XCTAssertEqual(log.head.decisions[id]?.basis, basis)
        }
    }

    func testRefusesATrackWhereTranscriptTimeIsNotTimelineTime() throws {
        let rate = FrameRate.r30
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        let asset = AssetRef(contentHash: "a", path: "/a", duration: TimeValue(seconds: Rational(10)),
                             frameRate: rate, hasVideo: false, hasAudio: true)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .audio, name: "A1"))
        let id = log.head.assets.keys.first!
        // Trimmed clip: source starts at 2 s, so word times no longer equal timeline times.
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: TimeValue(seconds: Rational(2)), duration: TimeValue(seconds: Rational(5))), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: .clientRule(rule: "place"))))
        let plan = WordEdit.plan(removing: [1], from: sample)
        XCTAssertThrowsError(try log.head.commands(applying: plan, toTrack: 0, basis: .clientRule(rule: "x"))) { e in
            guard case WordEditError.trackNotDirectlyAddressable = e as! WordEditError else { return XCTFail("\(e)") }
        }
    }
}
