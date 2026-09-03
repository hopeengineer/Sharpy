// Speaker index logic. The model path itself was validated on the user's real reel — one speaker
// correctly found (not hallucinated extras), 21 turns, 78.5 s of speech in 88 s, at 3x realtime.
// These cover the reasoning built on top of that, which is where the editing decisions come from.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class SpeakerIndexTests: XCTestCase {
    func s(_ x: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(x * 100), 100)) }
    func turn(_ speaker: Int, _ a: Double, _ b: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, range: TimeRange(start: s(a), end: s(b)))
    }

    /// A two-hander: A talks, B answers, A comes back.
    var conversation: SpeakerIndex {
        SpeakerIndex(asset: NodeID(contentOf: "a"),
                     turns: [turn(0, 0, 5), turn(1, 5, 12), turn(0, 12, 15)],
                     speakerCount: 2)
    }

    func testLookupByTime() {
        XCTAssertEqual(conversation.speaker(at: s(2)), 0)
        XCTAssertEqual(conversation.speaker(at: s(8)), 1)
        XCTAssertEqual(conversation.speaker(at: s(13)), 0)
        XCTAssertNil(conversation.speaker(at: s(20)), "past the end nobody is speaking")
    }

    func testShareOfVoiceAddsUpPerSpeakerNotPerTurn() {
        let share = conversation.shareOfVoice
        XCTAssertEqual(share[0]?.seconds.doubleValue, 8, "5 s plus 3 s across two turns")
        XCTAssertEqual(share[1]?.seconds.doubleValue, 7)
    }

    /// Speaker changes are the cheapest legitimate cut points in a conversation, so they have to be
    /// exactly the boundaries — not every turn edge.
    func testSpeakerChangesAreTheHandovers() {
        XCTAssertEqual(conversation.speakerChanges.map { $0.seconds.doubleValue }, [5, 12])
    }

    func testConsecutiveTurnsBySameSpeakerAreNotAChange() {
        let index = SpeakerIndex(asset: NodeID(contentOf: "a"),
                                 turns: [turn(0, 0, 5), turn(0, 5, 9), turn(1, 9, 12)],
                                 speakerCount: 2)
        XCTAssertEqual(index.speakerChanges.map { $0.seconds.doubleValue }, [9],
                       "a pause in one person's speech is not a handover")
    }

    func testASingleVoicePieceHasNoChanges() {
        let index = SpeakerIndex(asset: NodeID(contentOf: "a"), turns: [turn(0, 0, 60)], speakerCount: 1)
        XCTAssertTrue(index.speakerChanges.isEmpty)
        XCTAssertEqual(index.shareOfVoice[0]?.seconds.doubleValue, 60)
    }

    /// A word belongs to whoever was speaking when it *started* — the only rule that stays stable
    /// for a word that straddles a handover.
    func testWordsTakeTheSpeakerTheyStartedUnder() {
        func w(_ i: Int, _ text: String, _ a: Double, _ b: Double) -> Word {
            Word(index: i, text: text, range: TimeRange(start: s(a), end: s(b)), confidence: Rational(9, 10))
        }
        let transcript = Transcript(asset: NodeID(contentOf: "a"),
                                    words: [w(0, "hello", 1, 2), w(1, "there", 4.8, 5.4), w(2, "yes", 6, 7)],
                                    engines: ["whisper"])
        let labelled = transcript.labelled(with: conversation)
        XCTAssertEqual(labelled.words[0].speaker, "speaker 0")
        XCTAssertEqual(labelled.words[1].speaker, "speaker 0", "it starts at 4.8, before the 5.0 handover")
        XCTAssertEqual(labelled.words[2].speaker, "speaker 1")
        XCTAssertTrue(labelled.engines.contains("speakerkit"))
        XCTAssertEqual(labelled.text, transcript.text, "labelling changes nothing about the words")
    }

    func testWordsOutsideEveryTurnAreLeftUnlabelled() {
        let transcript = Transcript(asset: NodeID(contentOf: "a"),
                                    words: [Word(index: 0, text: "offscreen", range: TimeRange(start: s(30), end: s(31)), confidence: .one)],
                                    engines: ["whisper"])
        XCTAssertNil(transcript.labelled(with: conversation).words[0].speaker,
                     "guessing a speaker for speech nobody was diarized over would be a fabrication")
    }
}
