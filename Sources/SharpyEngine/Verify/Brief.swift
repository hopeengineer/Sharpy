// The brief, made falsifiable.
//
// "Misread the intent" was the one category of bad edit nothing could catch — a serious video cut
// funny, an apology given a comedy rhythm. It is uncatchable for a specific reason: it produces a
// *self-consistent wrong answer*. Every downstream check validates against the misreading, so they
// all pass. You cannot catch a misreading by checking against the reading.
//
// So the fix is not a cleverer checker. It is a brief that can be contradicted. A one-line brief —
// "audience, awareness level, one sentence on what the viewer should feel" — is unfalsifiable, and
// that is exactly why nothing catches its misreading. Give it a register, stakes, and a list of
// devices that would be wrong, and "made a serious video funny" stops being a taste failure and
// becomes an assertion violation with a timecode.
//
// The project spec already applies this discipline to house rules: each compiles to an assertion,
// and one that cannot compile is stored as a warning rather than silently ignored. This applies
// the same rule to the brief itself.

import Foundation

/// How the piece should carry itself. Not a mood — a constraint on which devices are available.
public enum Register: String, Sendable, Codable, CaseIterable {
    case grave, earnest, neutral, playful, irreverent

    /// Devices that contradict this register. Editing convention, not taste: a whip transition in
    /// a memorial reads as a mistake to every viewer, whatever anyone's preference.
    public var prohibitedByDefault: Set<EditingDevice> {
        switch self {
        case .grave: return [.whip, .soundOnCut, .comedicTiming, .memeCaption, .speedRamp, .zoomPunch]
        case .earnest: return [.memeCaption, .comedicTiming]
        case .neutral: return []
        case .playful: return []
        case .irreverent: return []
        }
    }
}

/// What it costs to be wrong. Scales the confidence required to ship without review — a surgeon
/// does not use the same threshold for a mole and a tumour.
public enum Stakes: String, Sendable, Codable, CaseIterable {
    case routine, elevated, high, irreversible

    /// Confidence a decision must carry to ship unattended at these stakes.
    public var shipConfidence: Rational {
        switch self {
        case .routine: return Rational(70, 100)
        case .elevated: return Rational(85, 100)
        case .high: return Rational(95, 100)
        case .irreversible: return Rational(101, 100)   // unreachable: always holds for review
        }
    }
}

/// A named editorial device, so a brief can forbid one by name and an assertion can find it.
public enum EditingDevice: String, Sendable, Codable, CaseIterable {
    case whip, dissolve, soundOnCut, comedicTiming, memeCaption, speedRamp, zoomPunch, jumpCut, musicBed
}

public struct Brief: Sendable, Codable {
    public var audience: String
    /// One sentence on what the viewer should do or feel. Human-readable, not checkable — which is
    /// precisely why the fields below exist alongside it.
    public var intent: String
    public var register: Register
    public var stakes: Stakes
    /// Devices forbidden beyond the register's own defaults.
    public var prohibitedDevices: Set<EditingDevice>
    /// Devices the piece must use — an unfulfilled requirement is as much a miss as a violation.
    public var requiredDevices: Set<EditingDevice>
    /// House rules in the client's own words. Ones that compile become assertions; ones that do
    /// not are surfaced as warnings rather than quietly dropped.
    public var houseRules: [String]

    public init(audience: String, intent: String, register: Register, stakes: Stakes,
                prohibitedDevices: Set<EditingDevice> = [], requiredDevices: Set<EditingDevice> = [],
                houseRules: [String] = []) {
        self.audience = audience; self.intent = intent
        self.register = register; self.stakes = stakes
        self.prohibitedDevices = prohibitedDevices; self.requiredDevices = requiredDevices
        self.houseRules = houseRules
    }

    /// Everything forbidden here: the register's defaults plus anything named explicitly.
    public var allProhibited: Set<EditingDevice> { register.prohibitedByDefault.union(prohibitedDevices) }

    /// What a brief can actually check. A brief that compiles to nothing is a brief that cannot be
    /// contradicted, and the caller should be told so rather than left with false comfort.
    public struct Compilation: Sendable {
        public let checkable: [String]
        public let uncheckable: [String]
        public var canBeContradicted: Bool { !checkable.isEmpty }
    }

    public func compile() -> Compilation {
        var checkable: [String] = []
        var uncheckable: [String] = []
        checkable.append("register \(register.rawValue) forbids \(allProhibited.map(\.rawValue).sorted().joined(separator: ", "))")
        checkable.append("stakes \(stakes.rawValue) requires confidence \(stakes.shipConfidence) to ship unattended")
        if !requiredDevices.isEmpty {
            checkable.append("must use \(requiredDevices.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        // House rules are free text. Only the ones naming a device we know can become assertions.
        for rule in houseRules {
            let lower = rule.lowercased()
            if let device = EditingDevice.allCases.first(where: { lower.contains($0.rawValue.lowercased()) }) {
                checkable.append("house rule mentions \(device.rawValue): \"\(rule)\"")
            } else {
                uncheckable.append(rule)
            }
        }
        if intent.split(separator: " ").count < 3 {
            uncheckable.append("intent is too short to mean anything: \"\(intent)\"")
        }
        return Compilation(checkable: checkable, uncheckable: uncheckable)
    }
}

/// Which device a decision used, so a brief can be checked against the record.
/// `Decision.params["device"]` carries the name; a decision that uses no named device has none.
extension Decision {
    public var device: EditingDevice? {
        params["device"].flatMap { EditingDevice(rawValue: $0) }
    }
}

// MARK: - Assertions the brief compiles to

/// The one that closes the "made a serious video funny" hole. It is only possible because the
/// brief states a register: with a one-line brief there is nothing to contradict.
public struct NoProhibitedDeviceForTheRegister: Assertion {
    public let brief: Brief
    public init(brief: Brief) { self.brief = brief }
    public let name = "no device contradicts the brief's register"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        let forbidden = brief.allProhibited
        return c.document.uniqueDecisions.compactMap { entry in
            guard let device = entry.decision.device, forbidden.contains(device) else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: "\(device.rawValue) is forbidden in a \(brief.register.rawValue) piece",
                                    at: entry.decision.at)
        }
    }
}

public struct RequiredDevicesAreUsed: Assertion {
    public let brief: Brief
    public init(brief: Brief) { self.brief = brief }
    public let name = "every device the brief requires appears"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.warn
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        let used = Set(c.document.uniqueDecisions.compactMap { $0.decision.device })
        return brief.requiredDevices.subtracting(used).sorted { $0.rawValue < $1.rawValue }.map {
            AssertionFailure(assertion: name, category: category, mode: mode,
                             detail: "the brief requires \($0.rawValue) and the edit never uses it", at: nil)
        }
    }
}

/// Stakes scale the bar for shipping unattended. At `irreversible` nothing clears it — which is
/// the point: some pieces should always be looked at, and that should be a setting rather than a
/// hope.
public struct StakesRaiseTheShipBar: Assertion {
    public let brief: Brief
    public init(brief: Brief) { self.brief = brief }
    public let name = "decisions meet the confidence bar for these stakes"
    public let category = AssertionCategory.provenance
    public let mode = AssertionMode.hold
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        let bar = brief.stakes.shipConfidence
        return c.document.uniqueDecisions.compactMap { entry in
            let conf = entry.decision.basis.confidence
            guard conf < bar else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: "\(entry.decision.kind.rawValue) rests on \(conf); \(brief.stakes.rawValue) stakes require \(bar)",
                                    at: entry.decision.at)
        }
    }
}

/// A brief nothing can contradict is a brief that cannot catch a misreading. This warns rather
/// than blocks — an unfalsifiable brief is a process problem, not a broken render.
public struct BriefCanBeContradicted: Assertion {
    public let brief: Brief
    public init(brief: Brief) { self.brief = brief }
    public let name = "the brief states something checkable"
    public let category = AssertionCategory.provenance
    public let mode = AssertionMode.warn
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        let compilation = brief.compile()
        var out: [AssertionFailure] = []
        if !compilation.canBeContradicted {
            out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                        detail: "nothing in this brief can be contradicted, so a misreading of it cannot be caught", at: nil))
        }
        for rule in compilation.uncheckable {
            out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                        detail: "cannot be checked, so it is only advice: \"\(rule)\"", at: nil))
        }
        return out
    }
}

extension Verifier {
    /// The standard set plus everything this brief compiles to.
    public static func forBrief(_ brief: Brief) -> Verifier {
        Verifier(assertions: Verifier.standard.assertions + [
            NoProhibitedDeviceForTheRegister(brief: brief),
            RequiredDevicesAreUsed(brief: brief),
            StakesRaiseTheShipBar(brief: brief),
            BriefCanBeContradicted(brief: brief),
        ])
    }
}
