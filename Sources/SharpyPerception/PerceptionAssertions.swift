// Assertions that need to have looked at the material.
//
// The structural checks in the engine can run on the document alone. These cannot: whether a cut
// lands inside a word, whether a caption is on screen long enough to read, whether text sits
// inside the safe area — all of it requires the perception index. That is the point at which a
// linter stops being a schema validator and starts catching the faults an editor would.
//
// Each one states what it cannot check. An assertion that quietly passes because its input was
// missing is worse than no assertion: it converts an unknown into a false assurance.

import Foundation
import SharpyEngine

/// The perception an assertion may consult, keyed to the asset it describes.
public struct PerceptionContext: Sendable {
    public let transcript: Transcript?
    public let vision: VisionIndex?
    public let shots: ShotIndex?
    /// Output frame size, for safe-area geometry.
    public let width: Int
    public let height: Int

    public init(transcript: Transcript? = nil, vision: VisionIndex? = nil, shots: ShotIndex? = nil,
                width: Int = 1920, height: Int = 1080) {
        self.transcript = transcript; self.vision = vision; self.shots = shots
        self.width = width; self.height = height
    }
}

/// Where the cuts fall in source time, which is what these checks compare against perception.
/// A cut in the record carries its timeline position; the source instant it corresponds to is what
/// the transcript and the vision index are indexed by.
func sourceCutInstants(_ document: Document) -> [(timeline: TimeValue, source: TimeValue)] {
    var out: [(TimeValue, TimeValue)] = []
    for track in document.timeline.tracks where track.kind == .audio || track.kind == .video {
        for clip in track.clips where clip.start > .zero {
            // The join at the head of a clip is a cut; the source instant is where it resumes.
            out.append((clip.start, clip.source.start))
        }
    }
    return out
}

// MARK: - Speech

/// A cut inside a word is the most audible edit fault there is, and the cheapest to detect once
/// word timings exist. It blocks rather than warns: there is no deliberate version of it.
public struct NoCutLandsInsideAWord: Assertion {
    public let perception: PerceptionContext
    /// How far from a word boundary still counts as clean. One frame at 30 fps is 33 ms; 20 ms is
    /// tighter than that and comfortably inside a consonant.
    public let tolerance: TimeValue
    public init(perception: PerceptionContext, tolerance: TimeValue = TimeValue(seconds: Rational(20, 1000))) {
        self.perception = perception; self.tolerance = tolerance
    }
    public let name = "no cut lands inside a spoken word"
    public let category = AssertionCategory.audio
    public let mode = AssertionMode.block

    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        guard let transcript = perception.transcript else {
            // Only report the gap when there is speech to have cut into.
            guard c.document.timeline.tracks.contains(where: { $0.kind == .audio && !$0.clips.isEmpty }) else { return [] }
            return [AssertionFailure(assertion: name, category: category, mode: .warn,
                                     detail: "there is a speech track but no transcript, so this check could not run", at: nil)]
        }
        return sourceCutInstants(c.document).compactMap { cut in
            guard let word = transcript.word(at: cut.source) else { return nil }
            let fromStart = (cut.source - word.range.start).seconds.doubleValue
            let toEnd = (word.range.end - cut.source).seconds.doubleValue
            let tol = tolerance.seconds.doubleValue
            guard fromStart > tol, toEnd > tol else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: String(format: "the cut lands %.0f ms into \"%@\" (word %d)", fromStart * 1000, word.text, word.index),
                                    at: cut.timeline)
        }
    }
}

/// Cutting where the transcript is uncertain is how a meaning-inverting error ships. The words
/// either side of a join are the ones a viewer notices, so they carry a higher bar than the rest.
public struct CutsRestOnConfidentWords: Assertion {
    public let perception: PerceptionContext
    public let floor: Rational
    public init(perception: PerceptionContext, floor: Rational = Rational(7, 10)) {
        self.perception = perception; self.floor = floor
    }
    public let name = "cuts do not land on low-confidence speech"
    public let category = AssertionCategory.audio
    public let mode = AssertionMode.hold

    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        guard let transcript = perception.transcript else { return [] }
        return sourceCutInstants(c.document).compactMap { cut in
            let nearby = transcript.words.filter {
                abs(($0.range.start - cut.source).seconds.doubleValue) < 0.5 ||
                abs(($0.range.end - cut.source).seconds.doubleValue) < 0.5
            }
            guard let worst = nearby.min(by: { $0.confidence < $1.confidence }), worst.confidence < floor else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: "the cut sits beside \"\(worst.text)\", which only \(worst.confidence) of the engines agree on",
                                    at: cut.timeline)
        }
    }
}

// MARK: - Picture

/// Text outside the title-safe area is cropped on some displays and covered by platform UI on
/// others. The 90 % convention predates streaming and still describes where the chrome lands.
public struct TextIsInsideTheSafeArea: Assertion {
    public let perception: PerceptionContext
    /// Fraction of the frame considered safe. 0.9 is the broadcast title-safe convention.
    public let safeFraction: Double
    public init(perception: PerceptionContext, safeFraction: Double = 0.9) {
        self.perception = perception; self.safeFraction = safeFraction
    }
    public let name = "on-screen text sits inside the title-safe area"
    public let category = AssertionCategory.legibility
    public let mode = AssertionMode.warn

    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        guard let vision = perception.vision else { return [] }
        let w = Double(vision.width), h = Double(vision.height)
        let marginX = w * (1 - safeFraction) / 2, marginY = h * (1 - safeFraction) / 2
        var out: [AssertionFailure] = []
        var reported = Set<String>()
        for frame in vision.frames {
            for line in frame.text {
                let outside = line.box.x < marginX || line.box.y < marginY
                    || line.box.maxX > w - marginX || line.box.maxY > h - marginY
                guard outside, !reported.contains(line.text) else { continue }
                reported.insert(line.text)
                out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                            detail: "\"\(line.text)\" reaches outside the \(Int(safeFraction * 100))% safe area",
                                            at: frame.time))
            }
        }
        return out
    }
}

/// Text that is on screen for less time than it takes to read is decoration, not communication.
/// Neither the FCC nor WCAG publishes a caption reading-speed number — W3C points to external
/// captioning style guides — so this is a `craft_rule` with a stated justification rather than a
/// platform requirement, and it warns rather than blocks.
public struct TextIsOnScreenLongEnoughToRead: Assertion {
    public let perception: PerceptionContext
    /// Milliseconds per word. 300 ms is about 200 wpm, a common subtitle guideline.
    public let millisecondsPerWord: Double
    public init(perception: PerceptionContext, millisecondsPerWord: Double = 300) {
        self.perception = perception; self.millisecondsPerWord = millisecondsPerWord
    }
    public let name = "on-screen text is up long enough to read"
    public let category = AssertionCategory.legibility
    public let mode = AssertionMode.warn

    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        guard let vision = perception.vision, vision.frames.count > 1 else { return [] }
        // How long each distinct line is present, from the sampling interval.
        let interval = (vision.frames[1].time - vision.frames[0].time).seconds.doubleValue
        var firstSeen: [String: TimeValue] = [:]
        var duration: [String: Double] = [:]
        for frame in vision.frames {
            for line in frame.text {
                if firstSeen[line.text] == nil { firstSeen[line.text] = frame.time }
                duration[line.text, default: 0] += interval
            }
        }
        return duration.compactMap { (text, onScreen) in
            let words = max(text.split(separator: " ").count, 1)
            let needed = Double(words) * millisecondsPerWord / 1000
            guard onScreen < needed else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: String(format: "\"%@\" is %d word(s) but on screen about %.1f s; reading it needs ~%.1f s",
                                                   text, words, onScreen, needed),
                                    at: firstSeen[text])
        }.sorted { ($0.at?.seconds.doubleValue ?? 0) < ($1.at?.seconds.doubleValue ?? 0) }
    }
}

/// Cutting in the middle of a shot that the shot detector says is continuous produces a jump cut.
/// Legitimate as a device, jarring as an accident — so it warns, and names the shot so the agent
/// can decide which it was.
public struct CutsFallOnShotBoundaries: Assertion {
    public let perception: PerceptionContext
    public let tolerance: TimeValue
    public init(perception: PerceptionContext, tolerance: TimeValue = TimeValue(seconds: Rational(3, 10))) {
        self.perception = perception; self.tolerance = tolerance
    }
    public let name = "cuts fall on shot boundaries rather than inside a shot"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.warn

    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        guard let shots = perception.shots, shots.shots.count > 1 else { return [] }
        let tol = tolerance.seconds.doubleValue
        return sourceCutInstants(c.document).compactMap { cut in
            guard let shot = shots.shot(at: cut.source) else { return nil }
            let fromStart = (cut.source - shot.range.start).seconds.doubleValue
            let toEnd = (shot.range.end - cut.source).seconds.doubleValue
            guard fromStart > tol, toEnd > tol else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: String(format: "the cut is %.1f s inside shot %d — a jump cut unless it is deliberate", fromStart, shot.index),
                                    at: cut.timeline)
        }
    }
}

extension Verifier {
    /// The standard set plus everything the perception index makes checkable.
    public static func withPerception(_ perception: PerceptionContext, brief: Brief? = nil) -> Verifier {
        let base = brief.map { Verifier.forBrief($0).assertions } ?? Verifier.standard.assertions
        return Verifier(assertions: base + [
            NoCutLandsInsideAWord(perception: perception),
            CutsRestOnConfidentWords(perception: perception),
            TextIsInsideTheSafeArea(perception: perception),
            TextIsOnScreenLongEnoughToRead(perception: perception),
            CutsFallOnShotBoundaries(perception: perception),
        ])
    }
}
