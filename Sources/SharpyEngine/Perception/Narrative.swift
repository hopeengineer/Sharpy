// What sets up what.
//
// The specification's own example of the failure this tool exists to prevent: "a sentence at 04:12
// sets up a payoff at 31:40". Every other layer here measures the material — words, faces, shots,
// levels — and none of them can represent that relation. Without it, cutting the setup and keeping
// the payoff is an edit no assertion can object to, and the result is a video that is technically
// perfect and makes no sense. That is precisely the "misread the intent, made a serious video
// funny, nobody notices until someone watches" failure.
//
// Two rules keep this honest, because narrative is the layer where a model is most tempted to
// invent:
//
//   A beat is addressed by WORD INDEX, not by time. Words survive cuts; timecodes do not. A link
//   pinned to 04:12 is wrong the moment anything earlier is trimmed, and a narrative index that
//   silently rots is worse than none.
//
//   A link is a `structuralInference` and never a measurement. Nobody measured that one sentence
//   pays off another — a model read it that way. It carries its own reasoning so a person can
//   disagree with it, and it sits below every measured fact in the basis order.

import Foundation

public enum NarrativeRole: String, Sendable, Codable, CaseIterable {
    /// The opening claim that buys attention.
    case hook
    /// Establishes something a later beat depends on.
    case setup
    /// Lands something an earlier beat established.
    case payoff
    /// Supports a claim — a number, a demo, a quote.
    case evidence
    /// Interesting, load-bearing for nothing.
    case aside
    case callToAction
}

public struct NarrativeBeat: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    /// Inclusive word indices from the transcript. Words survive cuts; timecodes do not.
    public let firstWord: Int
    public let lastWord: Int
    public let role: NarrativeRole
    /// The agent's one-line reading, kept so a person can disagree with the reasoning rather than
    /// only with the outcome.
    public let summary: String
    public let confidence: Rational

    public init(id: String = UUID().uuidString, firstWord: Int, lastWord: Int,
                role: NarrativeRole, summary: String, confidence: Rational = Rational(3, 4)) {
        self.id = id; self.firstWord = firstWord; self.lastWord = lastWord
        self.role = role; self.summary = summary; self.confidence = confidence
    }

    public func contains(word index: Int) -> Bool { index >= firstWord && index <= lastWord }
    public var wordCount: Int { lastWord - firstWord + 1 }

    /// A reading, never a measurement — see the note at the top of this file.
    public func basis() -> Basis {
        .structuralInference(evidence: ["words \(firstWord)–\(lastWord)", summary],
                             confidence: confidence)
    }
}

public struct NarrativeLink: Sendable, Codable, Equatable {
    /// The beat that must come first for the other to land.
    public let setupID: String
    public let payoffID: String
    /// Why the agent believes one depends on the other.
    public let why: String
    public let confidence: Rational

    public init(setupID: String, payoffID: String, why: String, confidence: Rational = Rational(3, 4)) {
        self.setupID = setupID; self.payoffID = payoffID
        self.why = why; self.confidence = confidence
    }
}

public struct NarrativeIndex: Sendable, Codable {
    public let beats: [NarrativeBeat]
    public let links: [NarrativeLink]

    public init(beats: [NarrativeBeat] = [], links: [NarrativeLink] = []) {
        self.beats = beats; self.links = links
    }

    public func beat(_ id: String) -> NarrativeBeat? { beats.first { $0.id == id } }
    public func beat(containing word: Int) -> NarrativeBeat? { beats.first { $0.contains(word: word) } }

    /// Links whose setup or payoff no longer exists in `survivingWords`.
    ///
    /// This is the whole point of the file. A payoff kept without its setup is a joke without its
    /// premise; a setup kept without its payoff is a promise the video never keeps. Both are
    /// invisible to every other check here.
    public func broken(survivingWords: Set<Int>) -> [BrokenLink] {
        links.compactMap { link in
            guard let setup = beat(link.setupID), let payoff = beat(link.payoffID) else {
                return BrokenLink(link: link, reason: .beatMissingFromIndex)
            }
            let setupSurvives = (setup.firstWord...setup.lastWord).contains { survivingWords.contains($0) }
            let payoffSurvives = (payoff.firstWord...payoff.lastWord).contains { survivingWords.contains($0) }
            switch (setupSurvives, payoffSurvives) {
            case (false, true): return BrokenLink(link: link, reason: .setupCut(payoff: payoff.summary))
            case (true, false): return BrokenLink(link: link, reason: .payoffCut(setup: setup.summary))
            default: return nil   // both kept, or both gone — either is coherent
            }
        }
    }

    /// Links where the payoff now plays BEFORE its setup. A move can do this without removing a
    /// single word, so it is checked separately from cutting.
    public func inverted(order: [Int]) -> [BrokenLink] {
        var position: [Int: Int] = [:]
        for (i, word) in order.enumerated() { position[word] = i }
        return links.compactMap { link in
            guard let setup = beat(link.setupID), let payoff = beat(link.payoffID),
                  let setupAt = position[setup.firstWord], let payoffAt = position[payoff.firstWord] else {
                return nil
            }
            guard payoffAt < setupAt else { return nil }
            return BrokenLink(link: link, reason: .payoffBeforeSetup(setup: setup.summary,
                                                                     payoff: payoff.summary))
        }
    }
}

public struct BrokenLink: Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable {
        case setupCut(payoff: String)
        case payoffCut(setup: String)
        case payoffBeforeSetup(setup: String, payoff: String)
        case beatMissingFromIndex
    }
    public let link: NarrativeLink
    public let reason: Reason

    public var description: String {
        switch reason {
        case .setupCut(let payoff):
            return "\"\(payoff)\" is kept but the setup it needs was cut — \(link.why)"
        case .payoffCut(let setup):
            return "\"\(setup)\" sets something up that is no longer paid off — \(link.why)"
        case .payoffBeforeSetup(let setup, let payoff):
            return "\"\(payoff)\" now plays before \"\(setup)\", which it depends on — \(link.why)"
        case .beatMissingFromIndex:
            return "a link refers to a beat that is not in the index"
        }
    }
}
