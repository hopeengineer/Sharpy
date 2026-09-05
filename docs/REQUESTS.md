# What the user has asked for

Every requirement given in conversation, with an honest status. Added because the user asks for
things as they occur to them, quickly, and a request that is only in a chat log is a request that
gets missed. **Nothing is marked done unless it is built AND measured.**

Status: **done** · **partial** — some of it works · **designed** — decided, not written ·
**open** — not started · **blocked** — needs something I do not have

---

## The north star

> "I'm not a video editor and I hardly have time to edit videos and learn this. There are other
> people like me who want to do content but can't. The AI agent should be able to handle this
> completely; the only part you have to do is the recording."

Everything below serves that. The measure of success is the autonomy trend — questions per hour of
footage, falling across videos — which is already instrumented (`autonomy_report`).

---

## 1. Watch, understand, edit from context — **partial**

> "An agent should be able to watch a video, understand the context, and make edits based on that
> context." · "not mechanical edits, full context aware logical editing"

- **done** — transcript (two engines voting, 3.06 % WER on 105,913 real words), speakers, shots,
  faces/text/hands, scene semantics (shot size, activity, setting), the editor's report.
- **done** — `move_segment`: the agent can now RESTRUCTURE, not only delete. This was missing
  entirely until 2026-09-04; the command set had no way to move anything.
- **partial** — narrative structure. `Narrative.swift` can represent "this sets up that", detect a
  payoff kept without its setup, and a payoff that now plays BEFORE its setup. **Not yet wired to
  an assertion or an MCP tool** — so nothing currently blocks a cut that orphans a payoff.
- **open** — the agent has no tool to WRITE a narrative index. It can read facts; it cannot yet
  record its reading of the structure.

## 2. Verify its own edit by watching it — **done**

> "Even when it does the edit, it should be able to easily watch it and see if the edit is done
> correctly... sometimes just one screenshot doesn't prove the transformation worked seamlessly."

`inspect_cuts` measures every join — luma jump, audio step, shot duration, on-screen text
continuity — and writes a **contact sheet**: three frames either side of each cut, join marked.
Inspection deliberately skips the delivery gate, because you inspect in order to judge a hold.

It earned itself immediately: on the author's reel it caught a caption cut mid-display that every
numeric check called clean.

## 3. Multi-take selection — **partial, needs real takes to validate**

> "I record videos in five or six different versions, manually find the best parts from each, and
> stitch them. The AI needs to do that automatically... camera angle, voice issue, how we talk,
> confidence. This is the one that doesn't work well."

**This is the user's actual daily workflow and the highest-value item here.**

- **done** — `TakeSelector` aligns takes by TRANSCRIPT (not time — the same line sits at a different
  clock position in every take) and scores each take's rendition of each sentence on four measured
  axes: fluency (fillers, restarts, mid-sentence stalls), clarity (the ASR engines' own per-word
  confidence — two models hesitating on a word is evidence it was mumbled), audio (speech-to-room
  separation), framing (subject present, steady, not drifting).
- It names **which axis decided each pick**, so a disagreement is arguable.
- **NOT VALIDATED** — no real multi-take material has been measured. It needs 5–6 takes of one
  script from the user. **This is the single thing most worth asking them for.**
- **open** — no MCP tool yet, and no automatic stitching of the chosen renditions into a timeline.
- **stated limit** — it does not judge "confidence". It measures four proxies and says which one
  drove the choice. Claiming to hear confidence would be inventing an authority it does not have.

## 4. Reference-driven editing — **partial**

> "A user gives a video and asks the AI to edit it exactly like that video."

- **done** — `EditStyle` measures a reference: cutting rate, median shot length, shot-size mix,
  words per minute, pause fraction, caption density, loudness.
- **open** — APPLYING a style to the user's own footage as targets/constraints.

## 5. "Tell me what to record" — **done (core), untested on a real reference**

> "You should be able to give a video and ask what type of recording you need for me to be able to
> create this exact edit."

`RecordingBrief` turns a measured reference into instructions for someone holding a phone: runtime,
orientation, word budget at the reference's pace, main framing, **how many cutaways to shoot** (with
a deliberate 1.6× overshoot, because a cutaway you did not shoot cannot be recovered), and a section
saying **what the brief cannot tell you** — e.g. whether cutaways were a second camera or a punch-in.

This is the direct answer to "the only part you have to do is the recording".

## 6. Sound: room to studio — **done**

> "Someone can record with noise... make recordings in a room sound like they are coming from a
> studio. See if we can do this with free models or the agent it is running on."

Answer: **macOS already ships it.** `AUSoundIsolation` is Apple's voice/noise separator, verified
present by enumerating the machine's 134 audio units. Chain: isolate → high-pass → de-mud → presence
→ dynamics → limiter. **Measured on the author's reel: 24.7 dB → 33.2 dB separation, +8.5 dB, at 52×
realtime.** No model download, no third party, no network.

Refuses to call itself an enhancement when separation does not improve, and writes an A/B file.

## 7. Audio character, not just decibels — **open**

> "Decibel doesn't necessarily mean it's the right audio. You need to identify audio from videos and
> see what fits our edits... based on those viral videos that me or the user shares. I don't know if
> decibel is enough."

**The user is right, and their own reel says so**: *"numbers can hear loud, it can't hear good."*

Designed, not built: an `AudioProfile` measuring the CHARACTER of a reference — spectral tilt and
balance, brightness (centroid), sibilance energy, crest factor (how compressed it is), loudness
range, and a direct-to-reverberant estimate (what makes a room sound like a room). Then match the
user's audio TO a reference profile instead of to a fixed preset. The current `studio` preset is a
guess; a reference profile is a measurement, which is the same discipline as everything else here.

## 8. Agent-authored effects, captions and caption styles — **open**

> "The agent should create its own transformations, its own effects, its own captions and caption
> styles. It should not just use what exists — that differentiates it from everyone else."

Nothing built. The right shape is effects as **data, not code**: a parameter/shader spec the agent
can author, name, validate and reuse, rendered by the existing Metal compositor. Caption styles are
the highest-value first case and the most tractable.

## 9. Import good effects from elsewhere, and export ours — **open, with a caveat to raise**

> "We need to find other effects from other places too, but only the good ones. Find a way to export
> those filters and effects."

The legitimate interoperable formats are **`.cube` LUTs** (colour, universally supported) and
**OpenFX**. Both import and export cleanly. Copying effects out of other people's software or apps
is a licensing problem, not a technical one, and I will say so rather than quietly do it.

## 10. Trending formats from Instagram / TikTok — **blocked, with an honest path**

> "It should identify edits that are trending on platforms like Instagram or TikTok and incorporate
> those."

I cannot scrape those platforms: it breaks their terms and needs credentials. **The honest path is
the one the user already described** — they share a video they like, and it is measured exactly
(§4/§5). A trending reel IS a reference video. That gives the same outcome without pretending to a
data source this project does not have.

If a legitimate feed is wanted later, the mechanism is already the right shape: whatever supplies
the reference, `EditStyle` measures it.

---

## Standing instructions

- **Quality over convenience, always.** Build ease is never a reason. It has caused three wrong
  decisions in this project, each recorded in the commit that reversed it.
- **Measure; never assume.** A component swap is justified only against the baseline it replaces, on
  material that could catch it being wrong.
- **Commit and push every time. Keep the README current.**
- **Don't stop to report** — keep going until it is done or something is genuinely needed.

## What I most need from the user

1. **5–6 takes of one script** — to validate §3, the highest-value unvalidated feature.
2. **A reference video** they want an edit to look like — to validate §4 and §5 end to end.
