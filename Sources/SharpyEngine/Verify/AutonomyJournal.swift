// Does this thing need a person less than it used to?
//
// That is M4's gate, and it is the only question that measures the actual goal — "one day no human
// needed at all apart from recording the video". Everything else in this repo measures whether a
// piece works; this measures whether the whole thing is getting closer to the point.
//
// The elicitation log answers it for ONE session. A rate falling within one video means nothing —
// questions naturally taper as a piece is understood. The claim worth making is across videos, so
// the record has to outlive the process.
//
// Two design choices that keep it honest:
//
//   The denominator is hours of FOOTAGE, not videos or sessions. Ten questions over ten hours and
//   ten over ten minutes are different products, and counting videos would reward short ones.
//
//   RESIDUE is recorded separately from questions. A question answered into a durable rule is
//   progress; the same question answered again every time is the system standing still while
//   appearing busy. Without that split, a rate can fall simply because the user gave up asking for
//   things.

import Foundation

/// One video's worth of asking.
public struct AutonomyEntry: Sendable, Codable, Equatable {
    public let videoID: String
    public let recordedAt: Date
    public let hoursOfFootage: Double
    public let questionsAsked: Int
    /// Answered but producing no durable artefact — these get asked again.
    public let residue: Int

    public var questionsPerHour: Double {
        hoursOfFootage > 0 ? Double(questionsAsked) / hoursOfFootage : 0
    }
    public var residuePerHour: Double {
        hoursOfFootage > 0 ? Double(residue) / hoursOfFootage : 0
    }

    public init(videoID: String, recordedAt: Date = Date(), hoursOfFootage: Double,
                questionsAsked: Int, residue: Int) {
        self.videoID = videoID; self.recordedAt = recordedAt
        self.hoursOfFootage = hoursOfFootage
        self.questionsAsked = questionsAsked; self.residue = residue
    }
}

public struct AutonomyTrend: Sendable {
    public let entries: [AutonomyEntry]
    /// Least-squares slope of questions-per-hour against video number. Negative is improvement.
    public let slope: Double
    public let first: Double
    public let last: Double
    /// M4's gate: reported AND falling across ten consecutive videos.
    public let meetsGate: Bool
    /// Why the gate is not met, when it is not. Never a bare false.
    public let shortfall: String?

    public var summary: String {
        guard entries.count >= 2 else {
            return "autonomy: \(entries.count) video(s) recorded — not enough to show a trend"
        }
        let direction = slope < 0 ? "falling" : (slope > 0 ? "RISING" : "flat")
        var line = String(format: "autonomy: %.1f → %.1f questions per hour across %d videos (%@, slope %+.2f)",
                          first, last, entries.count, direction, slope)
        if let shortfall { line += "\n  gate not met: \(shortfall)" }
        else if meetsGate { line += "\n  M4 gate MET" }
        return line
    }
}

public enum AutonomyJournalError: Error, CustomStringConvertible {
    case cannotWrite(String)
    public var description: String {
        switch self { case .cannotWrite(let s): return "autonomy journal: \(s)" }
    }
}

/// A durable record of how much help was needed, video by video.
public final class AutonomyJournal {
    public let url: URL
    /// M4 asks for ten consecutive routine videos.
    public static let gateWindow = 10

    public init(url: URL? = nil) throws {
        if let url {
            self.url = url
        } else {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Sharpy", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.url = root.appendingPathComponent("autonomy.json")
        }
    }

    public func entries() -> [AutonomyEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AutonomyEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Append one video's record.
    ///
    /// Appends rather than replaces even when the same videoID appears again: re-editing a piece is
    /// itself an event worth seeing, and silently overwriting would let a bad run be erased by a
    /// good one.
    public func record(_ entry: AutonomyEntry) throws {
        var all = entries()
        all.append(entry)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: url, options: .atomic)
        } catch {
            throw AutonomyJournalError.cannotWrite(String(describing: error))
        }
    }

    public func record(_ report: AutonomyReport, videoID: String) throws {
        try record(AutonomyEntry(videoID: videoID,
                                 hoursOfFootage: report.hoursOfFootage,
                                 questionsAsked: report.totalAsked,
                                 residue: report.residueByCategory.values.reduce(0, +)))
    }

    /// The trend over the most recent `window` videos.
    public func trend(window: Int = AutonomyJournal.gateWindow) -> AutonomyTrend {
        let recent = Array(entries().suffix(window))
        guard recent.count >= 2 else {
            return AutonomyTrend(entries: recent, slope: 0,
                                 first: recent.first?.questionsPerHour ?? 0,
                                 last: recent.last?.questionsPerHour ?? 0,
                                 meetsGate: false,
                                 shortfall: "only \(recent.count) video(s) recorded; the gate wants \(window)")
        }
        let rates = recent.map(\.questionsPerHour)
        let slope = AutonomyJournal.leastSquaresSlope(rates)

        var shortfall: String?
        if recent.count < window {
            shortfall = "only \(recent.count) of \(window) videos recorded"
        } else if slope >= 0 {
            shortfall = String(format: "rate is not falling (slope %+.2f per video)", slope)
        } else if recent.contains(where: { $0.hoursOfFootage <= 0 }) {
            // A zero denominator makes a rate of zero, which would flatter the trend.
            shortfall = "a video was recorded with no footage duration; the rate has no denominator"
        }
        return AutonomyTrend(entries: recent, slope: slope,
                             first: rates.first!, last: rates.last!,
                             meetsGate: shortfall == nil, shortfall: shortfall)
    }

    /// Least-squares slope against index. Used rather than "last < first" because two noisy
    /// endpoints can show improvement across a series that is going the wrong way.
    static func leastSquaresSlope(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var numerator = 0.0, denominator = 0.0
        for (i, y) in values.enumerated() {
            let dx = Double(i) - meanX
            numerator += dx * (y - meanY)
            denominator += dx * dx
        }
        return denominator == 0 ? 0 : numerator / denominator
    }
}
