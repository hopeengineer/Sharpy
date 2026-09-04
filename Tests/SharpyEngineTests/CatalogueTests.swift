// "Does this look like their work?" — the check nobody is left to perform when nobody is watching.
// Most of these are about the ways it must decline to answer.

import XCTest
@testable import SharpyEngine

final class CatalogueTests: XCTestCase {
    func catalogue() throws -> Catalogue {
        try Catalogue(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-catalogue-\(UUID().uuidString).json"))
    }

    func fill(_ c: Catalogue, cutsPerMinute: [Double]) throws {
        for (i, v) in cutsPerMinute.enumerated() {
            try c.record(CatalogueEntry(videoID: "v\(i)",
                                        recordedAt: Date(timeIntervalSince1970: Double(i) * 86400),
                                        metrics: ["cutsPerMinute": v]))
        }
    }

    /// With too little history there is no such thing as "their usual", and the gate must say so
    /// rather than compare against three numbers.
    func testTooLittleHistoryMakesNoClaim() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [10, 11, 12])
        let comparison = c.compare(["cutsPerMinute": 40])
        XCTAssertFalse(comparison.hasEnoughHistory)
        XCTAssertTrue(comparison.deviations.isEmpty, "40 is wild, and three pieces cannot prove it")
        XCTAssertTrue(comparison.summary.contains("too few"))
    }

    func testAnEditUnlikeTheirUsualWorkIsFlagged() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [10, 11, 12, 10, 11, 12])
        let comparison = c.compare(["cutsPerMinute": 45])
        XCTAssertTrue(comparison.hasEnoughHistory)
        XCTAssertEqual(comparison.deviations.count, 1)
        XCTAssertEqual(comparison.deviations[0].metric, "cutsPerMinute")
        XCTAssertTrue(comparison.summary.contains("unlike their usual"))
    }

    func testAnOrdinaryEditIsNotFlagged() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [10, 11, 12, 10, 11, 12])
        XCTAssertTrue(c.compare(["cutsPerMinute": 11.5]).deviations.isEmpty)
    }

    /// The reason for median-and-MAD rather than mean-and-SD: one experimental piece must not
    /// redefine what is normal and make the next ordinary edit look deviant.
    func testOneWildPieceDoesNotRedefineNormal() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [10, 11, 12, 10, 11, 200])   // one experiment
        let comparison = c.compare(["cutsPerMinute": 11])
        XCTAssertTrue(comparison.deviations.isEmpty,
                      "an ordinary edit stays ordinary; a mean would have moved to ~42 and flagged it")
    }

    /// A metric only a few past pieces carry has no norm. Comparing against the stragglers would
    /// invent one.
    func testAMetricMostOfTheCatalogueLacksIsSkipped() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [10, 11, 12, 10, 11, 12])
        try c.record(CatalogueEntry(videoID: "odd", metrics: ["cutsPerMinute": 11, "newAxis": 5]))
        let comparison = c.compare(["newAxis": 900])
        XCTAssertTrue(comparison.deviations.isEmpty, "one past value is not a norm")
    }

    /// A re-edit must not be compared against its own earlier self.
    func testAReEditIsNotMeasuredAgainstItself() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [10, 11, 12, 10, 11, 12])
        try c.record(CatalogueEntry(videoID: "target", metrics: ["cutsPerMinute": 45]))
        // Without the exclusion, 45 sits in the history and drags the spread wide enough to hide.
        let comparison = c.compare(["cutsPerMinute": 45], excluding: "target")
        XCTAssertEqual(comparison.deviations.count, 1, "excluded from its own norm, it is deviant again")
    }

    /// The basis must carry the sample size: a claim from five pieces is not a claim from fifty.
    func testTheBasisCarriesItsSampleSize() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [10, 11, 12, 10, 11, 12])
        let deviation = c.compare(["cutsPerMinute": 45]).deviations[0]
        guard case .measuredNorm(_, _, let evidence, let sampleSize) = deviation.basis() else {
            return XCTFail("a catalogue claim is a measured norm")
        }
        XCTAssertEqual(sampleSize, 6)
        XCTAssertEqual(evidence, .correlational,
                       "this measures what they have done, not what worked")
        XCTAssertGreaterThan(deviation.basis().rank, Basis.measuredMaterial(ref: "x", detail: "y", confidence: .one).rank,
                             "a norm must not outrank a measurement of this footage")
    }

    /// An identical history has zero spread. Any difference is then infinitely deviant, which is
    /// true and useless — but an identical value must still not be flagged.
    func testAnIdenticalHistoryDoesNotFlagAnIdenticalValue() throws {
        let c = try catalogue()
        try fill(c, cutsPerMinute: [12, 12, 12, 12, 12, 12])
        XCTAssertTrue(c.compare(["cutsPerMinute": 12]).deviations.isEmpty)
        XCTAssertEqual(c.compare(["cutsPerMinute": 30]).deviations.count, 1)
    }

    func testMedianAndMADAreCorrect() {
        XCTAssertEqual(Catalogue.median([3, 1, 2]), 2, accuracy: 0.0001)
        XCTAssertEqual(Catalogue.median([4, 1, 2, 3]), 2.5, accuracy: 0.0001)
        XCTAssertEqual(Catalogue.medianAbsoluteDeviation([1, 2, 3, 4, 100], median: 3), 1, accuracy: 0.0001)
    }
}
