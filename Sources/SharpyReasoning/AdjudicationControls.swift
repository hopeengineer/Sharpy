// Cases where the right answer is known, so the model's judgement can be scored rather than trusted.
//
// The first run of adjudication returned CUT on 18 of 18 candidates. A judge that never says no is
// not judging, and there is no way to tell assent from accuracy without cases that ought to come
// back KEEP. These are those cases.
//
// The KEEP cases are the ones that matter. Deliberate repetition looks identical to a false start
// under string matching — that is exactly why the model was brought in — so if the model cannot
// separate them, it has added nothing and must not be given a vote.

public struct AdjudicationControl: Sendable {
    public let before: String
    public let candidate: String
    public let after: String
    public let shouldCut: Bool
    public let note: String
}

public enum AdjudicationControls {
    /// Written from how people actually speak on camera, not from templates. The KEEP cases include
    /// the one the user described: pointing at two things in turn while saying the same words.
    public static let all: [AdjudicationControl] = [
        // ---- should KEEP: deliberate repetition, enumeration, callbacks ----
        .init(before: "so the funnel has two entry points and you have to feed both of them",
              candidate: "this hook goes here",
              after: "and this hook goes here. Two different audiences, two different doors in.",
              shouldCut: false, note: "pointing at two places in turn"),
        .init(before: "people ask me how long this actually took and they never believe the answer",
              candidate: "eight rounds",
              after: "eight rounds before it sounded like a human being made it.",
              shouldCut: false, note: "repeated for emphasis"),
        .init(before: "there are three things you need before you write a single line",
              candidate: "first, folders.",
              after: "Second, instruction files. Third, a way to check your own work.",
              shouldCut: false, note: "enumeration, not a retry"),
        .init(before: "I kept saying it could not hear the audio and nobody took that seriously",
              candidate: "it could not hear the audio.",
              after: "That is the whole problem in one sentence, so I will say it again at the end.",
              shouldCut: false, note: "deliberate callback the speaker flags"),
        .init(before: "the model is confident and the model is wrong and those are not the same thing",
              candidate: "confident and wrong",
              after: "is a worse place to be than confused and honest.",
              shouldCut: false, note: "rhetorical restatement"),
        .init(before: "here is the part that took the longest",
              candidate: "the sound design.",
              after: "The sound design is where four of those eight rounds went.",
              shouldCut: false, note: "topic sentence then expansion"),

        // ---- should CUT: genuine abandoned attempts ----
        .init(before: "and the reason the whole thing fell over is quite simple when you see it",
              candidate: "it took me three rounds",
              after: "took me eight rounds, eight rounds of sound design on one reel.",
              shouldCut: true, note: "wrong number, corrected without pausing"),
        .init(before: "what you actually want is a way for the thing to check itself",
              candidate: "so you give it a microphone, well not a microphone, you give it a",
              after: "so you give it an ear. You give it a way to hear its own output.",
              shouldCut: true, note: "abandoned mid-metaphor"),
        .init(before: "the second file is the one everybody forgets to write",
              candidate: "the second file is the instructions for the folder,",
              after: "the second file is the instructions for the agent, not the folder.",
              shouldCut: true, note: "wrong noun, restated correctly"),
        .init(before: "I want to be precise about the timing here because people misquote it",
              candidate: "it was about forty minutes before it",
              after: "it was twenty minutes before it came back with something usable.",
              shouldCut: true, note: "wrong figure, retried"),
        .init(before: "and then the last piece of this, the piece I nearly left out",
              candidate: "is that you have to, you have to sort of, the thing is you",
              after: "is that you have to let it fail out loud instead of guessing quietly.",
              shouldCut: true, note: "false starts before the real sentence"),
        .init(before: "so my advice if you are starting this week",
              candidate: "do not use a free model for the checking step because free models",
              after: "do not use a guessing model for the checking step. Cost is not the issue, checking is.",
              shouldCut: true, note: "kept going wrong, then said it right"),
    ]
}
