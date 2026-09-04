// Notes that become rules.
//
// The reel this project was measured against states the requirement in its own narration: "when a
// note is applied, you offer to promote it — this once, this project, or a standing rule. A
// preference repeated three times without being promoted is a tooling failure."
//
// That is not a nicety. It is the mechanism by which the tool needs a person less over time, which
// is the thing M4's gate measures. A system that accepts the same correction forever is not
// learning; it is being operated.
//
// The basis it produces is `learnedPreference`, rank 5 — below measured facts and above craft
// conventions. Deliberately: a preference is real evidence about this creator, and it is still
// weaker than a measurement of the material. Its confidence grows with occurrences and is capped,
// because ten repetitions of a preference is strong evidence about a person and never becomes a
// fact about video.

import Foundation

public enum PreferenceScope: String, Sendable, Codable, CaseIterable {
    /// Applied once, deliberately not remembered.
    case once
    /// Remembered for one project.
    case project
    /// Remembered for everything this creator does.
    case standing
}

public struct Preference: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    /// The note as the person put it. Never paraphrased — a promoted rule the user cannot
    /// recognise as their own words is one they cannot audit.
    public let text: String
    public let project: String?
    public private(set) var scope: PreferenceScope
    public private(set) var occurrences: Int
    public let firstSeen: Date
    public private(set) var lastSeen: Date
    public private(set) var promotedAt: Date?

    public init(id: String = UUID().uuidString, text: String, project: String?,
                scope: PreferenceScope = .once, occurrences: Int = 1,
                firstSeen: Date = Date(), lastSeen: Date = Date(), promotedAt: Date? = nil) {
        self.id = id; self.text = text; self.project = project; self.scope = scope
        self.occurrences = occurrences; self.firstSeen = firstSeen; self.lastSeen = lastSeen
        self.promotedAt = promotedAt
    }

    public var isPromoted: Bool { scope != .once }

    /// Repeated enough to be a rule, and still not one. The tooling failure, named.
    public var isUnpromotedResidue: Bool { occurrences >= StyleProfile.promotionThreshold && !isPromoted }

    /// Confidence from repetition, capped. Two sightings is a coincidence; ten is a habit; nothing
    /// is certainty, because a preference is about a person and people change their minds.
    public var confidence: Rational {
        let capped = min(occurrences, 10)
        return Rational(Int64(min(50 + capped * 5, 90)), 100)
    }

    /// The basis this preference can supply, or nil while it is still `once` — an unpromoted
    /// preference must not silently justify an edit the person did not ask to be repeated.
    public func basis() -> Basis? {
        guard isPromoted else { return nil }
        return .learnedPreference(ref: text, occurrences: occurrences, confidence: confidence)
    }

    mutating func sawAgain(at date: Date) {
        occurrences += 1
        lastSeen = date
    }

    mutating func promote(to scope: PreferenceScope, at date: Date) {
        self.scope = scope
        self.promotedAt = date
    }
}

public struct StyleProfileReport: Sendable {
    public let preferences: [Preference]
    /// Repeated at or past the threshold and still not promoted. The plan calls this a tooling
    /// failure; it is surfaced rather than counted quietly.
    public let unpromotedResidue: [Preference]
    public var standingRules: [Preference] { preferences.filter { $0.scope == .standing } }

    public var summary: String {
        guard !preferences.isEmpty else { return "style: nothing learned yet" }
        var lines = ["style: \(preferences.count) preference(s), \(standingRules.count) standing"]
        for p in unpromotedResidue {
            lines.append("  TOOLING FAILURE: \"\(p.text)\" asked \(p.occurrences) times and never promoted")
        }
        return lines.joined(separator: "\n")
    }
}

/// What the caller should do about a note it just recorded.
public enum PreferenceOutcome: Sendable, Equatable {
    case recorded(id: String, occurrences: Int)
    /// Repeated enough that the person should be offered a rule.
    case offerPromotion(id: String, text: String, occurrences: Int)
}

public final class StyleProfile {
    /// Three, from the specification's own wording.
    public static let promotionThreshold = 3

    public let url: URL
    private var preferences: [Preference]

    public init(url: URL? = nil) throws {
        if let url {
            self.url = url
        } else {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Sharpy", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.url = root.appendingPathComponent("style.json")
        }
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([Preference].self, from: data) {
            preferences = decoded
        } else {
            preferences = []
        }
    }

    /// Notes matching an existing preference increment it rather than creating a duplicate.
    /// Matching is on normalised text: "keep the wides" and "Keep the wides." are the same request,
    /// and treating them as two would hide the repetition this whole file exists to notice.
    static func normalise(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    @discardableResult
    public func note(_ text: String, project: String? = nil, at date: Date = Date()) throws -> PreferenceOutcome {
        let key = StyleProfile.normalise(text)
        guard !key.isEmpty else { throw StyleProfileError.emptyNote }
        if let index = preferences.firstIndex(where: {
            StyleProfile.normalise($0.text) == key && $0.project == project
        }) {
            preferences[index].sawAgain(at: date)
            let p = preferences[index]
            try save()
            if p.occurrences >= StyleProfile.promotionThreshold && !p.isPromoted {
                return .offerPromotion(id: p.id, text: p.text, occurrences: p.occurrences)
            }
            return .recorded(id: p.id, occurrences: p.occurrences)
        }
        let new = Preference(text: text, project: project, firstSeen: date, lastSeen: date)
        preferences.append(new)
        try save()
        return .recorded(id: new.id, occurrences: 1)
    }

    @discardableResult
    public func promote(_ id: String, to scope: PreferenceScope, at date: Date = Date()) throws -> Preference {
        guard let index = preferences.firstIndex(where: { $0.id == id }) else {
            throw StyleProfileError.noSuchPreference(id)
        }
        guard scope != .once else { throw StyleProfileError.cannotPromoteToOnce }
        preferences[index].promote(to: scope, at: date)
        try save()
        return preferences[index]
    }

    /// Rules that apply to a piece of work: standing ones always, project ones for that project.
    public func applicable(project: String?) -> [Preference] {
        preferences.filter {
            $0.scope == .standing || ($0.scope == .project && $0.project != nil && $0.project == project)
        }
    }

    public func all() -> [Preference] { preferences }

    public func report() -> StyleProfileReport {
        StyleProfileReport(preferences: preferences,
                           unpromotedResidue: preferences.filter(\.isUnpromotedResidue))
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(preferences).write(to: url, options: .atomic) }
        catch { throw StyleProfileError.cannotWrite(String(describing: error)) }
    }
}

public enum StyleProfileError: Error, Equatable, CustomStringConvertible {
    case emptyNote
    case noSuchPreference(String)
    case cannotPromoteToOnce
    case cannotWrite(String)
    public var description: String {
        switch self {
        case .emptyNote: return "a preference needs words"
        case .noSuchPreference(let id): return "no preference \(id)"
        case .cannotPromoteToOnce: return "promotion means project or standing; `once` is what it already was"
        case .cannotWrite(let s): return "style profile: \(s)"
        }
    }
}
