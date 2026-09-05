// Choosing takes by how they JOIN, not line by line. Lives with the perception tests because the
// assembler is there; the join measurement it relies on is tested next to the audio code.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception
@testable import SharpyRender

/// The choice itself: does taking joins into account actually change what gets picked?
final class JoinAwareChoiceTests: XCTestCase {
    func t(_ s: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(s * 1000), 1000)) }

    func rendition(_ take: Int, at start: Double, score: (Double, Double, Double)) -> Rendition {
        Rendition(takeIndex: take,
                  range: TimeRange(start: t(start), end: t(start + 2)),
                  words: [], fluency: score.0, clarity: score.1, audio: score.2,
                  framing: nil, notes: [])
    }

    /// Without an audio source the choice is per-line quality — the old behaviour, kept as the
    /// honest fallback rather than pretending to measure joins that were never measured.
    func testWithoutAudioItFallsBackToPerLineQuality() {
        let group = AttemptGroup(
            attempts: [rendition(0, at: 0, score: (0.5, 0.5, 0.5)),
                       rendition(1, at: 100, score: (0.9, 0.9, 0.9))],
            text: "a line", firstAt: t(0), spreadOut: false, members: [0, 1])
        let chosen = Assembler.chooseByJoins([group], source: nil)
        XCTAssertEqual(chosen.first?.1.takeIndex, 1, "the better take, when joins are unknown")
    }

    /// A single line has no joins, so the best rendition wins outright.
    func testASingleLineIsJustItsBestTake() {
        let group = AttemptGroup(
            attempts: [rendition(0, at: 0, score: (0.2, 0.2, 0.2)),
                       rendition(1, at: 50, score: (0.95, 0.95, 0.95))],
            text: "only line", firstAt: t(0), spreadOut: false, members: [0])
        XCTAssertEqual(Assembler.chooseByJoins([group], source: nil).first?.1.takeIndex, 1)
    }

    /// On real audio, the path chosen with joins measured must differ from the greedy per-line
    /// pick at least somewhere — otherwise measuring joins bought nothing.
    func testOnRealAudioJoinsChangeAtLeastOneChoice() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/20260904_014657.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no recording") }
        let source = try AudioSource(url: url, sampleRate: 48_000, channels: 1)

        // Six lines, each with three attempts spread across the recording.
        var groups: [AttemptGroup] = []
        for line in 0..<6 {
            let attempts = (0..<3).map { take in
                rendition(take, at: 40 + Double(line) * 3 + Double(take) * 110,
                          // Deliberately close in quality, so joins are what decide.
                          score: (0.80 + Double(take) * 0.01, 0.80, 0.80))
            }
            groups.append(AttemptGroup(attempts: attempts, text: "line \(line)",
                                       firstAt: t(40 + Double(line) * 3),
                                       spreadOut: false, members: [line]))
        }
        let greedy = groups.map { $0.best!.takeIndex }
        let byJoins = Assembler.chooseByJoins(groups, source: source).map { $0.1.takeIndex }
        XCTAssertEqual(byJoins.count, groups.count)
        XCTAssertNotEqual(greedy, byJoins,
                          "measuring joins changed nothing — greedy \(greedy), joined \(byJoins)")
    }
}
