// The mechanism by which the tool stops needing to be told the same thing. If it is wrong, the
// system is being operated rather than learning, and M4's gate can never move.

import XCTest
@testable import SharpyEngine

final class StyleProfileTests: XCTestCase {
    func profile() throws -> StyleProfile {
        try StyleProfile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-style-\(UUID().uuidString).json"))
    }

    /// The threshold comes from the specification's own wording, and the offer must arrive AT it —
    /// not after, which would be the fourth time of asking.
    func testTheThirdRepeatOffersARule() throws {
        let p = try profile()
        XCTAssertEqual(try p.note("keep the wide shots"), .recorded(id: p.all()[0].id, occurrences: 1))
        guard case .recorded(_, let second) = try p.note("keep the wide shots") else { return XCTFail() }
        XCTAssertEqual(second, 2, "twice is a coincidence")
        guard case .offerPromotion(_, let text, let n) = try p.note("keep the wide shots") else {
            return XCTFail("the third time must offer a rule")
        }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(text, "keep the wide shots")
    }

    /// Punctuation and case must not hide a repetition. Treating "Keep the wides." and "keep the
    /// wides" as different preferences is how a system asks the same question forever while its
    /// records show it never repeated itself.
    func testWordingVariationsAreTheSamePreference() throws {
        let p = try profile()
        try p.note("Keep the wides.")
        try p.note("keep the wides")
        guard case .offerPromotion = try p.note("KEEP THE WIDES!") else {
            return XCTFail("three phrasings of one request is still one request")
        }
        XCTAssertEqual(p.all().count, 1)
    }

    /// The named tooling failure: repeated enough to be a rule, and still not one.
    func testRepeatedAndNeverPromotedIsReportedAsAToolingFailure() throws {
        let p = try profile()
        for _ in 0..<4 { try p.note("cut the filler words") }
        let report = p.report()
        XCTAssertEqual(report.unpromotedResidue.count, 1)
        XCTAssertTrue(report.summary.contains("TOOLING FAILURE"))
        XCTAssertTrue(report.summary.contains("asked 4 times"))
    }

    func testPromotingClearsTheResidue() throws {
        let p = try profile()
        for _ in 0..<3 { try p.note("cut the filler words") }
        let id = p.all()[0].id
        try p.promote(id, to: .standing)
        XCTAssertTrue(p.report().unpromotedResidue.isEmpty)
        XCTAssertEqual(p.report().standingRules.count, 1)
    }

    /// An unpromoted preference must not silently justify an edit. The person applied it once and
    /// did not ask for it to be repeated.
    func testAnUnpromotedPreferenceSuppliesNoBasis() throws {
        let p = try profile()
        try p.note("warmer grade")
        XCTAssertNil(p.all()[0].basis(), "applied once is not a rule")
        try p.promote(p.all()[0].id, to: .project)
        XCTAssertNotNil(p.all()[0].basis())
    }

    /// A preference sits below measured facts and above craft conventions, and never becomes a
    /// certainty however often it is repeated — it is evidence about a person, not about video.
    func testABasisRanksBelowMeasurementAndIsNeverCertain() throws {
        let p = try profile()
        for _ in 0..<40 { try p.note("no zooms") }
        try p.promote(p.all()[0].id, to: .standing)
        guard case .learnedPreference(_, let occurrences, let confidence)? = p.all()[0].basis() else {
            return XCTFail("a promoted preference must supply a learnedPreference basis")
        }
        XCTAssertEqual(occurrences, 40)
        XCTAssertLessThanOrEqual(confidence, Rational(90, 100), "40 repetitions is a habit, not a fact")
        let measured = Basis.measuredMaterial(ref: "x", detail: "y", confidence: .one)
        XCTAssertGreaterThan(p.all()[0].basis()!.rank, measured.rank,
                             "a preference must never outrank a measurement")
        XCTAssertLessThan(p.all()[0].basis()!.rank, Basis.craftRule(rule: "r", why: "w").rank,
                          "…and it is better evidence than a general convention")
    }

    /// Scope must be honoured: a rule for one project must not leak into another.
    func testProjectRulesDoNotLeakBetweenProjects() throws {
        let p = try profile()
        try p.note("teal grade", project: "series-a")
        try p.promote(p.all()[0].id, to: .project)
        try p.note("always -14 LUFS")
        try p.promote(p.all().first { $0.text == "always -14 LUFS" }!.id, to: .standing)

        XCTAssertEqual(p.applicable(project: "series-a").count, 2)
        XCTAssertEqual(p.applicable(project: "series-b").map(\.text), ["always -14 LUFS"],
                       "another project gets the standing rule and nothing else")
    }

    func testTheProfileSurvivesTheProcess() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-style-\(UUID().uuidString).json")
        let first = try StyleProfile(url: url)
        try first.note("keep the wides")
        try first.note("keep the wides")
        let second = try StyleProfile(url: url)
        guard case .offerPromotion = try second.note("keep the wides") else {
            return XCTFail("a preference learned yesterday must count today")
        }
    }

    func testAnEmptyNoteIsRefused() throws {
        let p = try profile()
        XCTAssertThrowsError(try p.note("   ..!!  "))
    }

    /// The person's own words are kept. A promoted rule they cannot recognise is one they cannot
    /// audit, and an unauditable rule is how an autonomous system drifts.
    func testTheirWordingIsPreservedVerbatim() throws {
        let p = try profile()
        try p.note("Don't let the b-roll run long — it drags.")
        XCTAssertEqual(p.all()[0].text, "Don't let the b-roll run long — it drags.")
    }
}
