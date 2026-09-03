// The voting pair is a correctness decision, not a configuration detail.
//
// Two engines produce the transcript and their agreement IS the per-word confidence, which is
// what `CutsRestOnConfidentWords` reads before it will let a cut render. That only works if the
// second engine's errors are uncorrelated with the first's. Pair two engines that fail the same
// way and the merge does worse than miss the error — it marks it high confidence and waves it
// through.
//
// This is not hypothetical. On the user's reel, at "agent didn't make it worse":
//     Parakeet TDT v3   "Agent didn't make it worse"   correct
//     WhisperKit        "Agent did make it worse"      meaning inverted
//     Apple             "Agent did make it worse"      inverted the same way
// The pair WhisperKit+Apple agrees and ships the inversion. WhisperKit+Parakeet disputes the word
// at confidence 0.55, under the 0.7 floor, and the cut is held.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class VotingPairTests: XCTestCase {

    /// Guards the pairing itself. Apple's SpeechAnalyzer is live-preview only — measured at 5.30 %
    /// WER against 0.76 % for both voting engines, and it makes the meaning-inverting error. If a
    /// future change puts it back into the pair for being cheap to call, this fails.
    func testTheSecondVoteIsNotApple() {
        let version = IndexStore.versions["votedTranscript"]
        XCTAssertNotNil(version)
        XCTAssertFalse(version!.contains("apple"),
                       "Apple SpeechAnalyzer is live preview only; it inverts meaning where WhisperKit does")
        XCTAssertTrue(version!.contains("whisperkit") && version!.contains("parakeet"),
                      "the vote is WhisperKit + Parakeet — two architectures, uncorrelated errors")
    }

    /// The mechanism the pairing protects: two engines agreeing on a wrong word produce a
    /// confident wrong word. This is why "just add a cheap second engine" is not a safe move.
    func testAgreementOnAWrongWordProducesConfidenceNotSafety() {
        func t(_ engine: String, _ words: [String]) -> Transcript {
            Transcript(asset: NodeID(contentOf: "reel"),
                       words: words.enumerated().map { i, w in
                           Word(index: i, text: w,
                                range: TimeRange(start: TimeValue(seconds: Rational(Int64(i), 1)),
                                                 end: TimeValue(seconds: Rational(Int64(i) + 1, 1))),
                                confidence: Rational(9, 10), sources: [engine])
                       }, engines: [engine])
        }
        let truth = ["agent", "didn't", "make", "it", "worse"]

        // Both engines wrong the same way: the merge cannot tell, and says so with high confidence.
        let bothWrong = TranscriptMerge.agree(primary: t("whisper", ["agent", "did", "make", "it", "worse"]),
                                              secondary: t("apple", ["agent", "did", "make", "it", "worse"]))
        XCTAssertTrue(bothWrong.lowConfidence(below: Rational(7, 10)).isEmpty,
                      "agreement on an error reads as certainty — this is the failure mode, pinned")
        XCTAssertNotEqual(bothWrong.words.map(\.text), truth)

        // An independent engine disputes it, and the word drops under the floor.
        let independent = TranscriptMerge.agree(primary: t("whisper", ["agent", "did", "make", "it", "worse"]),
                                                secondary: t("parakeet", truth))
        let disputed = independent.lowConfidence(below: Rational(7, 10))
        XCTAssertTrue(disputed.contains { $0.text == "did" },
                      "the inverted word must fall under the confidence floor so the cut is held")
    }
}
