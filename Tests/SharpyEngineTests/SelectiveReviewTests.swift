// A review queue that lists everything is the same as no queue. These are mostly about that.

import XCTest
@testable import SharpyEngine

final class SelectiveReviewTests: XCTestCase {
    func t(_ x: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(x * 1000), 1000)) }
    func range(_ a: Double, _ b: Double) -> TimeRange { TimeRange(start: t(a), end: t(b)) }

    func item(_ a: Double, _ b: Double, _ severity: ReviewItem.Severity, _ reason: String = "r") -> ReviewItem {
        ReviewItem(range: range(a, b), severity: severity, reason: reason)
    }

    /// Two findings a second apart are one place to look. Listing them separately doubles the
    /// apparent work without adding any.
    func testNeighbouringFindingsMergeIntoOnePlaceToLook() {
        let queue = SelectiveReview.build(items: [
            item(10, 11, .hold), item(11.5, 12.5, .hold),
        ], pieceDuration: t(600))
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items[0].range.start.seconds.doubleValue, 10, accuracy: 0.001)
        XCTAssertEqual(queue.items[0].range.end.seconds.doubleValue, 12.5, accuracy: 0.001)
    }

    /// …but a blocking failure must never be folded into a neighbouring advisory. Hiding the thing
    /// that stops the render inside something optional is the worst possible merge.
    func testABlockingFailureIsNotMergedIntoAnAdvisory() {
        let queue = SelectiveReview.build(items: [
            item(10, 11, .advisory, "colour looks warm"),
            item(11.2, 12, .blocking, "cut lands mid-word"),
        ], pieceDuration: t(600))
        XCTAssertEqual(queue.items.count, 2)
        XCTAssertEqual(queue.items[0].severity, .blocking, "the blocker sorts first")
        XCTAssertEqual(queue.blocking.count, 1)
    }

    func testDistantFindingsStaySeparate() {
        let queue = SelectiveReview.build(items: [
            item(10, 11, .hold), item(300, 301, .hold),
        ], pieceDuration: t(600))
        XCTAssertEqual(queue.items.count, 2)
    }

    /// The point of the whole file: a queue covering most of the piece is a full review, and saying
    /// so is more useful than a long list.
    func testAQueueCoveringMostOfThePieceAdmitsItIsNotSelective() {
        let items = stride(from: 0.0, to: 90.0, by: 10.0).map { item($0, $0 + 9, .hold) }
        let queue = SelectiveReview.build(items: items, pieceDuration: t(100))
        XCTAssertFalse(queue.isSelective)
        XCTAssertTrue(queue.summary.contains("NOT SELECTIVE"))
        XCTAssertTrue(queue.summary.contains("full review with extra steps"))
    }

    func testASmallQueueIsSelectiveAndListsTheMoments() {
        let queue = SelectiveReview.build(items: [item(10, 12, .hold, "speaker unclear")],
                                          pieceDuration: t(600))
        XCTAssertTrue(queue.isSelective)
        XCTAssertEqual(queue.fractionOfPiece, 2.0 / 600.0, accuracy: 0.0001)
        XCTAssertTrue(queue.summary.contains("speaker unclear"))
    }

    func testNothingFlaggedSaysSoRatherThanBeingEmpty() {
        let queue = SelectiveReview.build(items: [], pieceDuration: t(120))
        XCTAssertTrue(queue.summary.contains("nothing flagged"))
        XCTAssertTrue(queue.isSelective)
    }

    /// Severity must survive the trip to a person unchanged. A `hold` quietly becoming an advisory
    /// is how something ships that should not have.
    func testAssertionModesMapToSeveritiesWithoutDrift() {
        let failures = [
            AssertionFailure(assertion: "a", category: .structural, mode: .block, detail: "d", at: t(10)),
            AssertionFailure(assertion: "b", category: .spatial, mode: .hold, detail: "d", at: t(50)),
            AssertionFailure(assertion: "c", category: .legibility, mode: .warn, detail: "d", at: t(90)),
        ]
        let items = SelectiveReview.items(from: failures)
        XCTAssertEqual(items.map(\.severity), [.blocking, .hold, .advisory])
    }

    /// A failure with no timestamp cannot point anywhere, and inventing a location for it would
    /// send a reviewer to the wrong second.
    func testAFailureWithNoTimeIsNotGivenAPlace() {
        let failures = [AssertionFailure(assertion: "a", category: .provenance, mode: .block,
                                         detail: "no basis", at: nil)]
        XCTAssertTrue(SelectiveReview.items(from: failures).isEmpty)
    }

    /// A window around a failure at t=0 must not start before the piece does.
    func testAWindowAtTheStartIsClamped() {
        let failures = [AssertionFailure(assertion: "a", category: .audio, mode: .warn,
                                         detail: "d", at: t(0.2))]
        let item = SelectiveReview.items(from: failures)[0]
        XCTAssertEqual(item.range.start.seconds.doubleValue, 0, accuracy: 0.0001)
    }

    /// Blockers first, then time order — a reviewer works down the list and must meet the things
    /// that stop the render before the things that merely might.
    func testTheQueueIsOrderedBySeverityThenTime() {
        let queue = SelectiveReview.build(items: [
            item(300, 301, .advisory), item(200, 201, .blocking),
            item(100, 101, .hold), item(50, 51, .blocking),
        ], pieceDuration: t(600))
        XCTAssertEqual(queue.items.map(\.severity), [.blocking, .blocking, .hold, .advisory])
        XCTAssertEqual(queue.items[0].range.start.seconds.doubleValue, 50, accuracy: 0.001)
    }
}
