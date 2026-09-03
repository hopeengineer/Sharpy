import XCTest
@testable import SharpyEngine

final class ElicitationTests: XCTestCase {
    var url: URL!
    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("elicit-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url); super.tearDown() }

    func testAskAndAnswer() {
        let log = ElicitationLog(url: url)
        let id = log.ask(.taste, "which of these four takes?", at: TimeValue(seconds: Rational(12)))
        XCTAssertEqual(log.open.count, 1)
        log.answer(id, with: "the third", compiledInto: "style profile: prefers the later, slower take")
        XCTAssertTrue(log.open.isEmpty)
        XCTAssertEqual(log.entries.first?.answer, "the third")
        XCTAssertNotNil(log.entries.first?.answeredAt)
    }

    /// The metric the whole file exists for. An answer that changed nothing durable means the same
    /// question comes back, and the log must say so rather than counting it as progress.
    func testAnAnswerThatChangesNothingIsCountedAsResidue() {
        let log = ElicitationLog(url: url)
        let a = log.ask(.taste, "which take?")
        let b = log.ask(.taste, "which take here?")
        log.answer(a, with: "the second", compiledInto: "style profile")
        log.answer(b, with: "the first")                       // deliberately nothing durable
        let report = log.report()
        XCTAssertEqual(report.byCategory[.taste], 2)
        XCTAssertEqual(report.residueByCategory[.taste], 1)
        XCTAssertEqual(report.stillNeedsAHuman, [.taste])
        XCTAssertTrue(report.summary.contains("will be asked again"))
    }

    func testTheRateHasADenominator() {
        let log = ElicitationLog(url: url)
        log.recordFootage(seconds: 7200)                        // two hours
        for i in 0..<6 { log.ask(.intent, "is this tangent on topic? \(i)") }
        let report = log.report()
        XCTAssertEqual(report.hoursOfFootage, 2, accuracy: 0.001)
        XCTAssertEqual(report.questionsPerHour, 3, accuracy: 0.001)
        XCTAssertTrue(report.summary.contains("3.0 per hour"))
    }

    func testNoFootageMeansNoRateRatherThanADivideByZero() {
        let log = ElicitationLog(url: url)
        log.ask(.failure, "no B-roll matches this claim; cut it or punch in?")
        XCTAssertEqual(log.report().questionsPerHour, 0)
    }

    /// Four of five categories name the artefact that retires them; `failure` is honest about
    /// being the residue that does not collapse.
    func testEachCategoryNamesWhatWouldRetireIt() {
        XCTAssertEqual(ElicitationCategory.taste.collapsesInto, "style profile (learned from picks)")
        XCTAssertEqual(ElicitationCategory.intent.collapsesInto, "the brief")
        XCTAssertEqual(ElicitationCategory.groundTruth.collapsesInto, "the enrollment registry")
        XCTAssertEqual(ElicitationCategory.permission.collapsesInto, "policy")
        XCTAssertNil(ElicitationCategory.failure.collapsesInto, "the hard residue must not pretend to collapse")
        XCTAssertEqual(ElicitationCategory.allCases.filter(\.canCollapse).count, 4)
    }

    func testTheLogSurvivesARestart() {
        let first = ElicitationLog(url: url)
        let id = first.ask(.groundTruth, "which face is the subject?")
        first.recordFootage(seconds: 600)
        first.answer(id, with: "the one on the left", compiledInto: "enrollment: subject = Sam")

        let reopened = ElicitationLog(url: url)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries[0].compiledInto, "enrollment: subject = Sam")
        XCTAssertEqual(reopened.report().hoursOfFootage, 600.0 / 3600, accuracy: 1e-9)
    }

    func testAnsweringAnUnknownIdIsANoOp() {
        let log = ElicitationLog(url: url)
        log.ask(.permission, "this cut drops the only mention of the sponsor — confirm?")
        log.answer("not-a-real-id", with: "yes")
        XCTAssertEqual(log.open.count, 1, "the real question is still open")
    }

    func testSummaryReadsAsProgressNotAsAPileOfCounts() {
        let log = ElicitationLog(url: url)
        log.recordFootage(seconds: 3600)
        let a = log.ask(.intent, "is the tangent at 14:20 on topic?")
        let b = log.ask(.groundTruth, "which face is the subject?")
        log.answer(a, with: "cut it", compiledInto: "brief: intent narrowed")
        log.answer(b, with: "left", compiledInto: "enrollment registry")
        let report = log.report()
        XCTAssertTrue(report.stillNeedsAHuman.isEmpty, "everything compiled, so nothing recurs")
        XCTAssertTrue(report.summary.contains("all collapsed into the brief"))
        XCTAssertTrue(report.summary.contains("all collapsed into the enrollment registry"))
        XCTAssertFalse(report.summary.contains("still needs a human"))
    }

    func testAnEmptyLogSaysSoPlainly() {
        let log = ElicitationLog(url: url)
        log.recordFootage(seconds: 1800)
        XCTAssertTrue(log.report().summary.contains("no questions asked"))
    }
}
