// Reading a format off a reference. If the threshold or the lag is wrong, the analysis is
// confidently wrong — which is worse than refusing, because the format then gets copied wrongly.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class LayoutAnalyzerTests: XCTestCase {

    /// Motion spans orders of magnitude — a held panel is 1e-6, a talking one 1e-2 — so the split
    /// has to happen in the log domain. A linear histogram puts nearly every sample in the first
    /// bin and picks a threshold up in the tail: measured on the real reference it chose 0.0123
    /// when 48% of samples were below 1e-4, and called talking panels frozen.
    func testTheThresholdSeparatesClustersOrdersOfMagnitudeApart() {
        let held = (0..<200).map { _ in Double.random(in: 0...2e-5) }
        let playing = (0..<200).map { _ in Double.random(in: 3e-3...3e-2) }
        let threshold = LayoutAnalyzer.otsu(held + playing)
        // Judged by what it CLASSIFIES, not by where the number lands. A threshold sitting just
        // inside the top of the held range is fine if it still calls held panels held; asserting a
        // position instead would be testing the arithmetic rather than the outcome.
        let heldWrong = held.filter { $0 > threshold }.count
        let playingWrong = playing.filter { $0 <= threshold }.count
        XCTAssertLessThan(heldWrong, 20, "\(heldWrong)/200 held samples called moving")
        XCTAssertEqual(playingWrong, 0, "a playing panel must never be called frozen")
    }

    func testAUniformDistributionStillYieldsAUsableThreshold() {
        let threshold = LayoutAnalyzer.otsu((0..<200).map { _ in Double.random(in: 0...0.05) })
        XCTAssertGreaterThan(threshold, 0)
        XCTAssertLessThan(threshold, 0.05)
    }

    /// A lag sitting ON the search boundary means the real alignment is outside the window, or
    /// there is none. Reporting it would be an artefact of where I stopped looking — and the first
    /// version did exactly that, announcing a confident "-3.00 s" echo that was the boundary.
    func testALagAtTheSearchBoundaryIsRefused() {
        // Unrelated noise: any apparent alignment is chance.
        let a = (0..<60).map { _ in Double.random(in: 0...1) }
        let b = (0..<60).map { _ in Double.random(in: 0...1) }
        if let found = LayoutAnalyzer.lag(a, b, maximum: 10) {
            XCTAssertLessThan(abs(found), 10, "a boundary lag must never be returned")
        }
    }

    /// A real offset must be found, or the echo cannot be recognised at all.
    func testAGenuineOffsetIsRecovered() {
        // A pulse train, and the same one delayed by 4 samples.
        let base = (0..<80).map { i -> Double in (i % 20 < 6) ? 1.0 : 0.0 }
        let delayed = (0..<80).map { i -> Double in ((i - 4) % 20 < 6 && i >= 4) ? 1.0 : 0.0 }
        let found = LayoutAnalyzer.lag(base, delayed, maximum: 12)
        XCTAssertNotNil(found, "a clear 4-sample delay must be recovered")
        XCTAssertEqual(abs(found ?? 0), 4, accuracy: 1)
    }

    /// Identical regions are maximally similar; different ones are not. This is what decides how
    /// many panels there are, so it has to be blunt and correct.
    func testSignatureDistanceIsZeroForIdenticalContent() {
        let a: [Float] = (0..<64).map { Float($0 * 3 % 255) }
        XCTAssertEqual(LayoutAnalyzer.distance(a, a), 0, accuracy: 1e-9)
        let b: [Float] = a.map { 255 - $0 }
        XCTAssertGreaterThan(LayoutAnalyzer.distance(a, b), 0.2)
    }

    /// The real thing, when the reference is present: three stacked panels carrying the same
    /// content, with an opening where they all run before taking turns.
    func testTheReferenceIsRecognisedAsAThreePanelFormat() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory()
            + "/Desktop/3 types of content you need to make as an entrepreneur.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no reference") }
        let analysis = try LayoutAnalyzer.analyse(url: url, maximumSeconds: 30)
        XCTAssertTrue(analysis.isSplitScreen, analysis.summary)
        XCTAssertEqual(analysis.panels, 3)
        XCTAssertTrue(analysis.stacked, "the panels are stacked, not side by side")
        XCTAssertGreaterThan(analysis.panelSimilarity, 0.8, "they carry the same person")
        // Each panel talks for a meaningful share — the failure mode was reporting them all frozen.
        for panel in analysis.activity {
            XCTAssertGreaterThan(panel.activeFraction, 0.2,
                                 "panel \(panel.index + 1) reads as frozen \(1 - panel.activeFraction) of the time")
        }
        XCTAssertNotNil(analysis.simultaneousOpening, "the hook runs all three panels together")
    }
}
