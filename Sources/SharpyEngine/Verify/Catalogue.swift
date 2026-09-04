// Does this edit look like the work this person actually publishes?
//
// Assertions catch faults. Nothing catches an edit that is technically perfect and simply not
// theirs — twice their usual cutting rate, half their usual shot length, delivered four LU louder
// than everything else on their channel. Under the autonomy goal nobody is watching for that, so
// it has to be measured.
//
// The comparison is against THEIR OWN catalogue, never a general norm. "Most creators cut every
// 3 seconds" is a fact about most creators and says nothing about someone whose whole style is long
// takes. This produces `measuredNorm` with its sample size attached, so a claim from five videos
// can be told apart from a claim from fifty.
//
// Robust statistics throughout: median and median-absolute-deviation, not mean and standard
// deviation. A catalogue is small and contains genuine outliers — one experimental piece would drag
// a mean far enough to make the next ordinary edit look deviant, and the gate would be reporting
// its own arithmetic rather than the work.

import Foundation

/// One finished piece, reduced to numbers that can be compared across pieces.
public struct CatalogueEntry: Sendable, Codable, Equatable {
    public let videoID: String
    public let recordedAt: Date
    /// Named measurements — cuts per minute, mean shot seconds, words per minute, LUFS, and so on.
    /// Free-form because the useful axes will grow, and a fixed struct would make adding one a
    /// migration.
    public let metrics: [String: Double]

    public init(videoID: String, recordedAt: Date = Date(), metrics: [String: Double]) {
        self.videoID = videoID; self.recordedAt = recordedAt; self.metrics = metrics
    }
}

public struct Deviation: Sendable, Equatable, CustomStringConvertible {
    public let metric: String
    public let value: Double
    public let median: Double
    /// Robust z-score: (value − median) / (1.4826 × MAD). The constant makes MAD comparable to a
    /// standard deviation for normal data, so the familiar thresholds mean what people expect.
    public let score: Double
    public let sampleSize: Int

    public var description: String {
        String(format: "%@ is %.1f (their usual is %.1f) — %.1f deviations out across %d piece(s)",
               metric, value, median, abs(score), sampleSize)
    }

    /// The basis a deviation supplies. `measuredNorm` carries the sample size so a claim from five
    /// pieces cannot be mistaken for a claim from fifty. Correlational: this measures what they
    /// have done, not what worked.
    public func basis() -> Basis {
        .measuredNorm(ref: "catalogue/\(metric)",
                      detail: String(format: "%.2f against a median of %.2f", value, median),
                      evidence: .correlational, sampleSize: sampleSize)
    }
}

public struct CatalogueComparison: Sendable {
    public let deviations: [Deviation]
    public let sampleSize: Int
    /// Below this the catalogue cannot support a claim, and none is made.
    public let minimumSample: Int

    public var hasEnoughHistory: Bool { sampleSize >= minimumSample }

    public var summary: String {
        guard hasEnoughHistory else {
            return "catalogue: \(sampleSize) previous piece(s) — too few to say what is normal (wants \(minimumSample))"
        }
        guard !deviations.isEmpty else {
            return "catalogue: consistent with their previous \(sampleSize) piece(s)"
        }
        return "catalogue: \(deviations.count) axis/axes unlike their usual work\n"
            + deviations.map { "  · " + $0.description }.joined(separator: "\n")
    }
}

public final class Catalogue {
    /// Flag beyond this many robust deviations. 3 is the conventional outlier bar and is strict
    /// enough that an ordinary edit does not trip it.
    public static let defaultThreshold = 3.0
    /// Five pieces is the fewest from which a median and a spread mean anything at all.
    public static let minimumSample = 5

    public let url: URL
    private var entries: [CatalogueEntry]

    public init(url: URL? = nil) throws {
        if let url {
            self.url = url
        } else {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Sharpy", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.url = root.appendingPathComponent("catalogue.json")
        }
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([CatalogueEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    public func all() -> [CatalogueEntry] { entries }

    public func record(_ entry: CatalogueEntry) throws {
        entries.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// Compare a candidate against everything recorded, excluding any entry with the same id — a
    /// re-edit must not be measured against itself.
    public func compare(_ metrics: [String: Double], excluding videoID: String? = nil,
                        threshold: Double = Catalogue.defaultThreshold) -> CatalogueComparison {
        let history = entries.filter { $0.videoID != videoID }
        var deviations: [Deviation] = []
        guard history.count >= Catalogue.minimumSample else {
            return CatalogueComparison(deviations: [], sampleSize: history.count,
                                       minimumSample: Catalogue.minimumSample)
        }
        for (metric, value) in metrics.sorted(by: { $0.key < $1.key }) {
            let past = history.compactMap { $0.metrics[metric] }
            // A metric absent from most of the catalogue has no norm to compare against; silently
            // comparing against the handful that have it would invent a norm from stragglers.
            guard past.count >= Catalogue.minimumSample else { continue }
            let m = Catalogue.median(past)
            let deviation = Catalogue.medianAbsoluteDeviation(past, median: m)
            // Zero MAD means every past value is identical; any difference is then infinitely
            // deviant, which is true but useless. Flag only a real difference.
            let score: Double
            if deviation == 0 {
                score = value == m ? 0 : (value > m ? .infinity : -.infinity)
            } else {
                score = (value - m) / (1.4826 * deviation)
            }
            if abs(score) > threshold {
                deviations.append(Deviation(metric: metric, value: value, median: m,
                                            score: score, sampleSize: past.count))
            }
        }
        return CatalogueComparison(deviations: deviations, sampleSize: history.count,
                                   minimumSample: Catalogue.minimumSample)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func medianAbsoluteDeviation(_ values: [Double], median m: Double) -> Double {
        median(values.map { abs($0 - m) })
    }
}
