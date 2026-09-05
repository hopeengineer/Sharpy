// The user's actual daily work: five takes, keep the best run of each line. If this picks wrongly
// it is worse than useless, because they would have to check every choice — which is the work it
// was meant to remove.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception
@testable import SharpyRender

final class TakeSelectionTests: XCTestCase {
    func t(_ x: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(x * 1000), 1000)) }

    /// Builds a take saying the given sentences, one word per 0.4 s, starting at `offset` — so the
    /// same line sits at a different clock position in every take, as it does in life.
    func take(_ index: Int, sentences: [String], offset: Double = 0,
              confidence: Double = 0.95, gapBefore: [Int: Double] = [:],
              speech: SpeechProfile? = nil, vision: VisionIndex? = nil) -> Take {
        var words: [Word] = []
        var clock = offset
        var i = 0
        for sentence in sentences {
            let tokens = sentence.split(separator: " ").map(String.init)
            for (n, token) in tokens.enumerated() {
                clock += gapBefore[i] ?? 0
                let last = n == tokens.count - 1
                words.append(Word(index: i, text: last ? token + "." : token,
                                  range: TimeRange(start: t(clock), end: t(clock + 0.35)),
                                  confidence: Rational(Int64(confidence * 100), 100)))
                clock += 0.4
                i += 1
            }
        }
        let transcript = Transcript(asset: NodeID(contentOf: "take\(index)"),
                                    words: words, engines: ["test"])
        return Take(index: index, url: URL(fileURLWithPath: "/tmp/take\(index).mov"),
                    transcript: transcript, vision: vision, speech: speech)
    }

    let script = ["the hook goes here", "then the explanation follows"]

    /// The core: identical content, one take stumbles, the clean one wins — and it must be aligned
    /// by TEXT, because the takes start at different times.
    func testTheCleanerTakeWinsEvenWhenItStartsAtADifferentTime() {
        let clean = take(0, sentences: script, offset: 0)
        let stumbled = take(1, sentences: ["the um hook goes here", "then the explanation follows"],
                            offset: 12.5)
        let selection = TakeSelector.select(takes: [clean, stumbled])
        let hook = selection.choices.first { $0.text.contains("hook") }
        XCTAssertNotNil(hook)
        XCTAssertEqual(hook?.chosen.takeIndex, 0, "the take without the filler")
        XCTAssertTrue(hook!.decidedBy.contains("fluency"), hook!.decidedBy)
    }

    /// A restart — the same word twice running — is the classic re-take trigger and must be caught.
    func testARestartLosesToACleanRun() {
        let clean = take(0, sentences: ["then the explanation follows"])
        let restarted = take(1, sentences: ["then the the explanation follows"])
        let selection = TakeSelector.select(takes: [clean, restarted])
        XCTAssertEqual(selection.choices.first?.chosen.takeIndex, 0)
        XCTAssertTrue(restarted.transcript.words.count > clean.transcript.words.count)
    }

    /// Two engines hesitating on the same words is real evidence of mumbling, and it is free to read.
    func testLowASRConfidenceLosesToClearDelivery() {
        let clear = take(0, sentences: ["then the explanation follows"], confidence: 0.97)
        let mumbled = take(1, sentences: ["then the explanation follows"], confidence: 0.45)
        let selection = TakeSelector.select(takes: [clear, mumbled])
        XCTAssertEqual(selection.choices.first?.chosen.takeIndex, 0)
        XCTAssertTrue(selection.choices.first!.decidedBy.contains("clarity"),
                      selection.choices.first!.decidedBy)
    }

    /// A long stall mid-sentence is what makes a line sound unsure.
    func testAMidSentenceStallLoses() {
        let steady = take(0, sentences: ["then the explanation follows"])
        let stalled = take(1, sentences: ["then the explanation follows"], gapBefore: [2: 1.4])
        let selection = TakeSelector.select(takes: [steady, stalled])
        XCTAssertEqual(selection.choices.first?.chosen.takeIndex, 0)
        XCTAssertTrue(stalled.transcript.words.count == steady.transcript.words.count)
    }

    /// Cleaner sound wins when everything else is equal.
    func testTheQuieterRoomWins() {
        let profileGood = SpeechProfile(speechLevel: -20, noiseFloor: -55, threshold: -45, runs: [])
        let profileNoisy = SpeechProfile(speechLevel: -20, noiseFloor: -33, threshold: -45, runs: [])
        let quiet = take(0, sentences: ["then the explanation follows"], speech: profileGood)
        let noisy = take(1, sentences: ["then the explanation follows"], speech: profileNoisy)
        let selection = TakeSelector.select(takes: [quiet, noisy])
        XCTAssertEqual(selection.choices.first?.chosen.takeIndex, 0)
        XCTAssertTrue(selection.choices.first!.decidedBy.contains("sound"))
    }

    /// A take with no Vision pass must not be ranked below one that happens to have been indexed.
    /// Scoring a missing measurement as zero would rank takes by their metadata.
    func testAMissingMeasurementIsNotAPenalty() {
        let face = DetectedBox(x: 40, y: 40, width: 20, height: 20, confidence: 0.9)
        let indexed = VisionIndex(asset: NodeID(contentOf: "a"),
                                  frames: (0..<4).map { FrameObservation(time: t(Double($0) * 0.5), faces: [face], hands: [], text: []) },
                                  width: 100, height: 100)
        let withVision = take(0, sentences: ["then the explanation follows"], vision: indexed)
        let without = take(1, sentences: ["then the explanation follows"])
        let selection = TakeSelector.select(takes: [withVision, without])
        XCTAssertEqual(selection.choices.first!.decidedBy, "a near tie — any of these would do",
                       "both are clean; the one lacking a Vision pass must not lose for that")
    }

    /// A line only some takes contain is reported, not silently dropped — it may be the best thing
    /// in the piece or a fluff nobody meant to keep, and only a person knows which.
    func testALineMissingFromSomeTakesIsReported() {
        let full = take(0, sentences: script + ["and one extra thought"])
        let short = take(1, sentences: script)
        let selection = TakeSelector.select(takes: [full, short])
        XCTAssertTrue(selection.inconsistent.contains { $0.contains("extra thought") })
        XCTAssertFalse(selection.choices.contains { $0.text.contains("extra thought") },
                       "a line only one take has cannot be a comparison")
    }

    /// Every pick carries the axis that decided it, so a person can disagree with the reasoning
    /// rather than only with the outcome.
    func testEveryChoiceExplainsItself() {
        let a = take(0, sentences: script)
        let b = take(1, sentences: ["the um hook goes here", "then the explanation follows"])
        for choice in TakeSelector.select(takes: [a, b]).choices {
            XCTAssertFalse(choice.decidedBy.isEmpty)
            XCTAssertFalse(choice.description.isEmpty)
        }
    }

    func testOneTakeIsNotASelection() {
        XCTAssertTrue(TakeSelector.select(takes: [take(0, sentences: script)]).choices.isEmpty)
    }
}

/// A line said twice on purpose is two beats, not a duplicate.
extension TakeSelectionTests {
    /// "This hook goes here" pointing at one thing, then at another, is two things the person
    /// meant. Nothing may merge or drop them, and they must be flagged for a human to confirm.
    func testARepeatedLineIsKeptTwiceAndFlagged() {
        let script = ["this hook goes here", "and this hook goes here", "then we are done"]
        let a = take(0, sentences: script)
        let b = take(1, sentences: script, offset: 9)
        let selection = TakeSelector.select(takes: [a, b])

        let hookChoices = selection.choices.filter { $0.text.lowercased().contains("hook goes here") }
        XCTAssertEqual(hookChoices.count, 2, "two beats must survive as two choices")
        XCTAssertFalse(selection.repeated.isEmpty, "and be flagged for a person to confirm")
        XCTAssertTrue(selection.summary.contains("said more than once"), selection.summary)
    }

    /// Monotonic matching: the second rendition of a repeated line must pair with the SECOND
    /// instance in the other take, not the first. Best-match-anywhere gets this wrong.
    func testRepeatedLinesPairInOrderNotByBestMatch() {
        let script = ["this hook goes here", "and this hook goes here", "then we are done"]
        let a = take(0, sentences: script)
        let b = take(1, sentences: script, offset: 20)
        let selection = TakeSelector.select(takes: [a, b])
        let hooks = selection.choices.filter { $0.text.lowercased().contains("hook goes here") }
        XCTAssertEqual(hooks.count, 2)
        // The two chosen renditions must be different moments, not the same one twice.
        XCTAssertNotEqual(hooks[0].chosen.range.start, hooks[1].chosen.range.start,
                          "two beats cannot both resolve to one moment")
    }
}
