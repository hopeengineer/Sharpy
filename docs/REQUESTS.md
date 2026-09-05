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
- Three alignment bugs were found by testing rather than reasoning, and are recorded in the commit:
  exact text matching fails (takes differ in precisely the words being judged); the spine was chosen
  by segment count, which made the *most hesitant* take the reference; and a long stall splits a
  sentence, so hesitant takes could not match at all.
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

## 11. Descript-style editing — edit by deleting words — **done**

> "I hope you built the descript feature, where you can edit by just deleting words — cutting out
> unnecessary words, silences, etc."

- **done** — `remove_words` cuts by the words, never by frames. It takes word indices, index ranges,
  `fillers: true`, and now **`text`: quote the phrase exactly as the transcript returned it**, which
  is the actual Descript gesture. Verified on the author's reel: quoting *"That crap was worse than
  my phone."* removed 7 words in one cut, 88.30 s → 85.70 s.
- A phrase that is not in the transcript is **refused**, not matched approximately — a near miss
  usually means working from a paraphrase, and cutting the closest match removes words nobody asked
  about.
- Every occurrence is cut, not the first, and it says so. Silently cutting one of two would leave
  the caller believing both were gone.
- **done** — `tighten_pauses` for silences.
- **open** — the human-facing document view. The agent-facing half is what an agent-first tool needs
  first, and it exists.

## 12. A repeated line is not a duplicate — **done**

> "You can't just remove something for similarity. If a user says 'this hook goes here' twice while
> pointing at two points, it doesn't mean one needs to be removed. That's why I keep saying
> contextual aware editing."

Correct, and it caught a real defect in take selection as it was being written. Fixed: matching is
**monotonic** (each take scanned forward only, so the second beat pairs with the second beat), and
**nothing removes a repetition**. Repeated lines are kept, paired in order, and flagged for a person
to confirm — with the warning threshold deliberately looser than the merge threshold, so it fires
before any merge would. Two tests pin it.

## 13. Cinematic filters / looks — **open, next**

> "You also need to add cinematic filters. The one I'm sharing is the unedited one; the one you've
> been checking is the edited one — it has a cinematic filter, which is why it looks yellowish,
> clean and nice."

Nothing built. The colour infrastructure is there and unused for this: OCIO 2.5.2 is linked, the
compositor already injects Metal shader code for colour transforms, and blending is in linear light,
which is what makes a film curve behave.

A look is a stack of measurable operations — exposure, contrast/film curve, white balance and tint,
lift/gamma/gain per channel, saturation, split-toning (warm highlights, cool shadows), vignette,
grain, and halation. Each has a number, so a look is data an agent can author, name, reuse, and be
held to — not a preset nobody can inspect. `.cube` LUT import/export is the interoperable form.

## 14. The agent builds its own tools as it goes — **designed, and genuinely possible**

> "This agent needs to be able to build tools as it goes and learn according to the job... if you
> find we don't have enough features to do that edit, the agent will create that feature and
> integrate it into the system. While the edit happens, the tool improves itself. Can we do that?"

**Yes, for effects — and it is already half-built without being used for this.**

`MetalCompositor` compiles its kernel from a Metal source STRING at runtime
(`device.makeLibrary(source:)`), and the colour pipeline already injects generated shader code into
it. So an agent can author a new effect as shader source plus named parameters, have it compiled,
measured and registered, and use it in the same session. That is real self-extension.

The boundary that keeps it honest, and it is not a limitation but the design:

- An effect is **data** — shader source and typed parameters — never arbitrary Swift. It runs inside
  the compositor's sandbox on pixels, and it cannot touch the filesystem, the network, or the
  document.
- It must **compile, then be measured** before it is usable: throughput against the existing gate,
  and a known-input/known-output check so an effect that silently produces black is caught.
- It carries a **basis** like every other decision, and it is `structuralInference` — the agent's own
  invention is not a measured fact and must not outrank one.
- Effects the agent writes are **saved and named**, so the second video benefits from the first. That
  is the same mechanism as `learnedPreference`, applied to capability rather than taste.

## 15. Multi-take inside ONE file — **open, and it changes the design**

> "This is a 10-minute video where I recorded the same thing multiple times."

`TakeSelector` assumes takes arrive as separate files. They do not: the user records **repeated
attempts inside one continuous recording**. That needs a step before selection — finding the take
boundaries by detecting repeated passages of the same script within a single transcript, which is
the same similarity machinery pointed at one file instead of several.

Noted here because it would otherwise be discovered on the day the footage arrives, and it is the
difference between the feature working and not.

---

## Standing instructions

- **Quality over convenience, always.** Build ease is never a reason. It has caused three wrong
  decisions in this project, each recorded in the commit that reversed it.
- **Measure; never assume.** A component swap is justified only against the baseline it replaces, on
  material that could catch it being wrong.
- **Commit and push every time. Keep the README current.**
- **Don't stop to report** — keep going until it is done or something is genuinely needed.

## What I most need from the user

1. ~~5–6 takes of one script~~ — **arriving**: a 10-minute 4K recording containing repeated takes,
   plus the edited 1:20 cut made from it. That single file validates §3 (take selection), §15
   (takes within one file), §13 (the cinematic look, by comparing unedited against edited), and the
   4K throughput figure the plan claims but this machine cannot currently verify.
2. **A reference video** they want an edit to look like — to validate §4 and §5 end to end.

### Context over pattern matching — the local model reading the transcript

> *"that's why I have been saying this should be full context aware editing not pattern matching"*

String matching finds a restart by seeing the same words twice. It cannot tell a fumble from a line
somebody repeated on purpose, because both look identical to it. A local model reading the words is
the only thing that can, so one was measured rather than assumed:

| asked | score on 12 known cases | what it actually did |
| --- | --- | --- |
| "did the speaker abandon this?" (yes/no) | 6/12 | answered CUT **12 times out of 12** — no information |
| a choice between two named alternatives | 6/12 | 4 of 6 deliberate repetitions kept; wrong cuts 6 → 1 |

Same score, opposite behaviour — which is why the control set exists at all. The model is good at
recognising speech somebody meant to say and poor at spotting a fumble, so it gets that half only:

- it may **veto** a cut the measurement proposed, never propose one;
- the two passes swap the option order, and an answer that moves with the options is discarded;
- a veto does not stand against a strong measurement — a retry inside 1.0 s that repeats two thirds
  of the words is somebody catching themselves, and the basis hierarchy already says
  `measuredMaterial` outranks `structuralInference`.

On the 10-minute recording: 18 candidates, 15 cut, 3 vetoed, 3 further vetoes overruled by the
measurement. Two of the three survivors are the same thesis line at 452 s and 599 s — one sentence
the speaker deliberately came back to, which no amount of string comparison could have told apart
from a stumble.

Still open: the model is 2/6 at finding fumbles unaided, so it adds nothing to detection. Every
veto is recorded and reviewable rather than applied silently.

### The three-panel edit now renders

`sharpy assemble <script.txt> <video> --out <file.mov>` builds it: one track per panel, the
speaking panel playing forward, the others held on the frame they stopped at, audio following
whoever is talking. On the user's recording — 88.5 s, 2655 frames, 13 beats, all three bands
carrying picture.

What it does correctly: bands centre on the measured face (28% down this recording) rather than
the middle of the frame; times snap to the video grid where the plan is made, so the plan printed
and the file rendered are the same edit; a band that never got a clip is detected as blank rather
than passing as "reframed".

What is still open:

- **The opening's echo cannot be measured from this reference.** Three attempts, all reported:
  panel motion correlation (nothing can beat "no shift" by a fifth when panels are 94% alike),
  panel picture correlation (no minimum), audio autocorrelation (returned its own search floor at
  4.35× strength — an artefact, now refused). The likely reason is that the reference shot its
  panels as separate takes, which cannot be recovered from one delayed take. `--echo <seconds>`
  sets it, and it says so rather than inventing a number.
- One scripted line — "Second: instruction files." — still does not locate in the recording.
- 8.7 fps rendering three panels, against 366 fps measured at four layers. The freezes are seeking
  backwards and rebuilding the reader; not yet investigated.

## What went wrong with the first three-panel render, and what stops it happening again

The first render passed every check it had. The user watched it and said it was 70% there with huge
mistakes, and asked not to be told what they were but for the app to find them, fix them, and stop
them recurring. Listening to the output — transcribing it and reading it against the script — found
six, none of which a screenshot could show:

| heard in the output | cause, in the code |
| --- | --- |
| "First folders" twice, with "Third hooks" between | the span for a line was a fixed-length word window (`CutScript.locate`); cut 4's window began inside cut 1's words |
| "Second instructions file" missing from the intro, heard later inside cut 5 | word matching was exact equality (`TakeSelector.similarity`); *instruction files* vs *instructions file* scored 1 of 3 |
| that line dropped without a word | the assembler skipped unmatched lines with `continue` and rendered anyway |
| "the right context" twice; cut 5 opening on the tail of cut 10 | overlapping spans; `collisions()` existed and the render path never called it |
| four lines chopped mid-sentence ("Automate it with a—", "Make it easy to—") | the window ended on the last MATCHED word, and the speaker's last words differed from the script |
| hook heard once, panels half a second apart | echo invented at 0.5 s; the reference's, measured from its audio, is 25 ms |

And from the picture, against the reference: no labels, no captions, a loose crop, and — found on
a third look — a panel frozen on a hand covering the lens, and a caption showing a word that had
been cut from the sound.

Every one of these has the same root: **the output was checked against the plan and the source,
never against the script or the reference.** A check that is not on the render path is decoration.

What the app does now, on every `sharpy assemble`:

1. **Locates lines by anchor, then extends to the sentence.** The best window is trimmed to
   words actually in the line (no line opens on the previous line's full stop), then grows to a
   pause, a full stop, or a word another line holds — whichever is first. Inflected and misheard
   words match. Result on the recording: 14 of 14 lines on their true segments, 0 overlaps.
2. **Asks before cutting.** An unmatched line, an overlap, or a lone unscripted word before a pause
   is a QUESTION, printed with its nearest candidate, and the render refuses without
   `--accept-problems` (or `--cut-stumbles` for the stumbles it proposes). Cutting "Claude—" before
   "CLAUDE.md" was right; cutting the garbled "CLAUDE.md" itself would have been wrong, and the rule
   was tightened to tell them apart: a false start is followed by a reset pause, a real word by
   the rest of its sentence.
3. **Dresses the panels from the reference's measurements**, not from taste: face size in the
   band (21% on the reference; the user's shot is already tighter at 29%, and the app now says so
   instead of printing the target as the result), label position and height, caption size and
   position, echo period from the audio's autocorrelation with boundary peaks refused.
4. **Holds on a face.** A frozen frame steps back to the last Vision sample with a face; a playing
   clip ends on its last face and holds while the final word plays.
5. **Listens to the result** (`ScriptReadback`): transcribes the output, checks every line is
   heard where the plan put it, that no beat's closing words open the next, that the speaker's
   actual closing words survive, that the hook is heard once, and that every caption is heard while
   it is shown.
6. **Measures the result against the reference** (`ReferenceComparison`): labels on every band,
   face size within tolerance, captions present, no band faceless for longer than the reference's.
7. **Exits non-zero if any of that fails.** The file exists; it is not the edit.

`sharpy readback <script> <source> <output> [--reference]` runs 5 and 6 on an existing file.

Measured on the user's recording: 13/13 lines heard in order, 0 repeated, 0 chopped, 111/111
captions heard while shown, all three bands labelled, faceless stretch 0.0 s on every band.
Rendering went from 9 fps to 288 fps: three tracks shared one decoder and seeked three times per
frame; each track now has its own.

Still open: the model-adjudicated self-correction is not wired into `assemble`; captions are
plain word groups (the reference emphasises one word per group in a second colour); no graphics.
