// M4's gate measures the actual goal — needing a person less over time. A gate that can be passed
// by accident measures nothing, so most of these are about the ways it must NOT pass.

import XCTest
@testable import SharpyEngine

final class AutonomyJournalTests: XCTestCase {
    func journal() throws -> AutonomyJournal {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-autonomy-\(UUID().uuidString).json")
        return try AutonomyJournal(url: url)
    }

    func entry(_ id: String, hours: Double, asked: Int, residue: Int = 0, day: Int) -> AutonomyEntry {
        AutonomyEntry(videoID: id, recordedAt: Date(timeIntervalSince1970: Double(day) * 86400),
                      hoursOfFootage: hours, questionsAsked: asked, residue: residue)
    }

    func testTheDenominatorIsFootageNotVideos() {
        let short = entry("a", hours: 0.1, asked: 10, day: 1)
        let long = entry("b", hours: 10, asked: 10, day: 2)
        XCTAssertEqual(short.questionsPerHour, 100, accuracy: 0.001)
        XCTAssertEqual(long.questionsPerHour, 1, accuracy: 0.001)
        // Counting videos would call these identical; they are not the same product.
    }

    func testAFallingRateAcrossTenVideosMeetsTheGate() throws {
        let j = try journal()
        for i in 0..<10 {
            try j.record(entry("v\(i)", hours: 1, asked: 20 - i, day: i))
        }
        let trend = j.trend()
        XCTAssertLessThan(trend.slope, 0)
        XCTAssertTrue(trend.meetsGate, trend.shortfall ?? "")
        XCTAssertTrue(trend.summary.contains("M4 gate MET"))
    }

    /// Fewer than ten videos is not a pass, however good the numbers look.
    func testTooFewVideosIsNotAPass() throws {
        let j = try journal()
        for i in 0..<4 { try j.record(entry("v\(i)", hours: 1, asked: 20 - i * 5, day: i)) }
        let trend = j.trend()
        XCTAssertLessThan(trend.slope, 0, "the numbers do fall")
        XCTAssertFalse(trend.meetsGate, "…but four videos is not evidence of a trend")
        XCTAssertTrue(trend.shortfall!.contains("4 of 10"))
    }

    /// The gate must not be passable by two flattering endpoints around a series going the wrong
    /// way. This series starts at 20 and ends at 19 while spending the middle far higher.
    func testTwoGoodEndpointsCannotHideARisingSeries() throws {
        let j = try journal()
        let asked = [20, 30, 32, 35, 34, 36, 38, 35, 37, 19]
        for (i, a) in asked.enumerated() { try j.record(entry("v\(i)", hours: 1, asked: a, day: i)) }
        let trend = j.trend()
        XCTAssertLessThan(trend.last, trend.first, "the endpoints alone look like an improvement")
        XCTAssertGreaterThan(trend.slope, 0, "the series is actually getting worse")
        XCTAssertFalse(trend.meetsGate)
        XCTAssertTrue(trend.shortfall!.contains("not falling"))
    }

    /// A video recorded with no footage duration makes a rate of zero, which would flatter the
    /// trend. It must be refused rather than counted.
    func testAZeroDenominatorIsRefusedNotCountedAsZero() throws {
        let j = try journal()
        for i in 0..<9 { try j.record(entry("v\(i)", hours: 1, asked: 20 - i, day: i)) }
        try j.record(entry("v9", hours: 0, asked: 0, day: 9))
        let trend = j.trend()
        XCTAssertFalse(trend.meetsGate)
        XCTAssertTrue(trend.shortfall!.contains("no footage duration"), trend.shortfall!)
    }

    /// Residue is tracked separately because a question answered into a durable rule is progress
    /// and the same question answered again forever is not.
    func testResidueIsRecordedSeparatelyFromQuestions() throws {
        let j = try journal()
        try j.record(entry("a", hours: 2, asked: 10, residue: 6, day: 1))
        let stored = j.entries().first!
        XCTAssertEqual(stored.questionsPerHour, 5, accuracy: 0.001)
        XCTAssertEqual(stored.residuePerHour, 3, accuracy: 0.001)
    }

    /// Re-editing a piece is an event worth seeing. Overwriting would let a bad run be erased by a
    /// good one, which is the one edit nobody should be able to make to their own scorecard.
    func testRecordingTheSameVideoAgainAppendsRatherThanReplaces() throws {
        let j = try journal()
        try j.record(entry("same", hours: 1, asked: 30, day: 1))
        try j.record(entry("same", hours: 1, asked: 2, day: 2))
        XCTAssertEqual(j.entries().count, 2)
        XCTAssertEqual(j.entries().map(\.questionsAsked), [30, 2])
    }

    func testTheJournalSurvivesTheProcess() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-autonomy-\(UUID().uuidString).json")
        let first = try AutonomyJournal(url: url)
        try first.record(entry("a", hours: 1, asked: 5, day: 1))
        let second = try AutonomyJournal(url: url)
        XCTAssertEqual(second.entries().count, 1, "a trend across videos cannot live in one process")
    }

    func testSlopeIsLeastSquaresNotEndpoints() {
        XCTAssertEqual(AutonomyJournal.leastSquaresSlope([1, 2, 3, 4]), 1, accuracy: 0.0001)
        XCTAssertEqual(AutonomyJournal.leastSquaresSlope([4, 3, 2, 1]), -1, accuracy: 0.0001)
        XCTAssertEqual(AutonomyJournal.leastSquaresSlope([5, 5, 5]), 0, accuracy: 0.0001)
    }
}
