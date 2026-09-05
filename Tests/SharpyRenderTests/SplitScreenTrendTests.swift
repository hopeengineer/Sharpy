// The three-band trend, built from the primitives rather than as a feature.
//
// One 9:16 frame split into three horizontal bands, the same recording in each, the audio offset so
// the three voices echo; then the bands take turns — one plays while the other two hold on a frame.
//
// This exists as a test because "do we have the features for a proper edit?" is only answerable by
// building something real out of them. If a trend needs a new special case in the compositor, the
// primitives were wrong. This one needs crop, placement, and freeze, and nothing else.

import XCTest
import CoreVideo
@testable import SharpyEngine
@testable import SharpyRender

final class SplitScreenTrendTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: .r30) }

    /// Three bands, each showing the middle third of the source, stacked to fill the frame.
    /// Cropping to a band and placing it in a band is what keeps faces the right shape — scaling a
    /// full frame into a third would squash everybody.
    func band(_ index: Int, asset: NodeID, source: TimeRange, start: TimeValue,
              frozen: Bool = false, holdFor: TimeValue? = nil) -> Clip {
        let third = Rational(1, 3)
        let placement = ClipPlacement(
            x: .zero, y: third * Rational(Int64(index)), width: .one,
            height: third,
            // Keep the centre of the frame in every band: crop the source to a horizontal slice.
            cropTop: Rational(1, 3), cropBottom: Rational(1, 3))
        if frozen, let holdFor {
            return Clip.freeze(asset: asset, at: source.start, frameDuration: t(1),
                               start: start, duration: holdFor, placement: placement)
        }
        return Clip(asset: asset, source: source, start: start, placement: placement)
    }

    func testTheThreeBandTrendIsExpressibleWithoutNewPrimitives() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "trend", frameRate: rate)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov", duration: t(900),
                                          frameRate: rate, hasVideo: true, hasAudio: true)))
        let asset = log.head.assets.keys.first!
        for i in 0..<3 { try log.append(.addTrack(kind: .video, name: "band\(i)")) }
        let basis = Basis.craftRule(rule: "three-band split with staggered entries",
                                    why: "a format that reads as three voices then resolves to one")

        // Phase 1: all three run, each offset by a second — the echo.
        for i in 0..<3 {
            let offset = Int64(i) * 30
            try log.append(.placeClip(
                track: i,
                clip: band(i, asset: asset,
                           source: TimeRange(start: t(offset), end: t(offset + 90)),
                           start: t(0)),
                decision: Decision(kind: .graphic, at: t(0), basis: basis)))
        }
        // Phase 2: band 0 speaks; bands 1 and 2 hold on a frame.
        try log.append(.placeClip(track: 0,
            clip: band(0, asset: asset, source: TimeRange(start: t(90), end: t(180)), start: t(90)),
            decision: Decision(kind: .graphic, at: t(90), basis: basis)))
        for i in 1..<3 {
            try log.append(.placeClip(track: i,
                clip: band(i, asset: asset, source: TimeRange(start: t(120), end: t(121)),
                           start: t(90), frozen: true, holdFor: t(90)),
                decision: Decision(kind: .speed, at: t(90), basis: basis)))
        }

        let document = log.head
        XCTAssertEqual(document.timeline.tracks.count, 3)
        XCTAssertEqual(document.timeline.duration, t(180), "three seconds of echo, then three of band 0")

        // The bands tile the frame exactly: no gap, no overlap.
        let placements = document.timeline.tracks.map { $0.clips[0].placement! }
        XCTAssertEqual(placements.map(\.y), [.zero, Rational(1, 3), Rational(2, 3)])
        XCTAssertTrue(placements.allSatisfy { $0.height == Rational(1, 3) })
        XCTAssertTrue(placements.allSatisfy { $0.cropTop == Rational(1, 3) && $0.cropBottom == Rational(1, 3) },
                      "each band shows the middle of the frame, so faces are not squashed")

        // The frozen bands hold: every instant of the hold shows one source frame.
        let held = document.timeline.tracks[1].clips.last!
        XCTAssertEqual(held.timelineSpan, t(90), "it occupies three seconds")
        // Not speed zero. A freeze is one frame of source stretched over the hold, so the true rate
        // is 1/90 — and reporting that honestly is better than special-casing it to zero, because
        // the same arithmetic is what makes slow motion work.
        XCTAssertEqual(held.speed, Rational(1, 90))
        XCTAssertLessThan(held.source.duration.seconds, Rational(1, 29),
                          "one frame of source is what makes it a freeze")
        XCTAssertEqual(held.sourceTime(at: t(120)).frame(at: rate), 120,
                       "the same frame throughout the hold")
    }

    /// The staggered entry is what makes it sound like three people. Expressed as three source
    /// offsets, not as an effect.
    func testTheEchoIsThreeSourceOffsetsNotAnEffect() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "trend", frameRate: rate)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov", duration: t(900),
                                          frameRate: rate, hasVideo: false, hasAudio: true)))
        let asset = log.head.assets.keys.first!
        for i in 0..<3 { try log.append(.addTrack(kind: .audio, name: "voice\(i)")) }
        let basis = Basis.craftRule(rule: "staggered voices", why: "reads as three people")
        for i in 0..<3 {
            try log.append(.placeClip(track: i,
                clip: Clip(asset: asset,
                           source: TimeRange(start: t(Int64(i) * 30), end: t(Int64(i) * 30 + 90)),
                           start: t(0)),
                decision: Decision(kind: .sound, at: t(0), basis: basis)))
        }
        // Audio tracks SUM rather than stack, so three offsets of one voice is literally an echo.
        let atOneSecond = log.head.audioClips(at: t(45))
        XCTAssertEqual(atOneSecond.count, 3, "all three sound at once")
        let sources = atOneSecond.map { $0.sourceTime.frame(at: rate) }.sorted()
        XCTAssertEqual(sources, [45, 75, 105], "one second apart, which is the echo")
    }
}
