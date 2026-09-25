# Voice — Writing in the User's Own Hand

**Date:** 2026-08-07
**Status:** Draft v1 (extends design.md §6 — a second *Signals* place, beside the Radar)
**Scope:** a corpus of the user's own prose, a profile derived from it, and a
drafting desk that writes new text in that voice.

---

## 1. Vision

The Radar (design.md §6) says *a machine could do this chore for you*. Voice says
the same thing about the chore nobody automates because the output has to sound
like a person: the mail, the message, the paragraph of explanation. An LLM will
write all three today, and all three come back in the flat committee register
every model defaults to — which is why people rewrite them, and why the time the
draft saved goes straight back out again.

The fix is not a better instruction. It is **evidence**: text the user has
already written, kept where the model can be shown it. So Voice is three things,
in the order the rest of this codebase does them — measure first, describe
second, act third:

1. **A corpus** — writing the user hands over, on purpose. Plain files under
   `~/Shifu/voice/`, theirs to read, edit, and delete.
2. **A profile** — half *measured* (deterministic statistics over the corpus, no
   model involved), half *described* (a short voice card the LLM writes from the
   samples). The measured half exists so the profile is not merely another
   opinion: numbers are checkable, and they are all the page has to show before
   any backend is configured.
3. **A drafting desk** — a prompt box that returns a draft built from the
   profile *and* verbatim excerpts, because few-shot with the user's real
   sentences beats every description of them.

Nothing here captures anything. The corpus is only what the user hands over — see
§2.3 for why the obvious idea (harvest their writing from the screen text Shifu
already has) is refused rather than deferred.

### Why it sits beside the Radar

The *Signals* band is "what a machine could take over". Radar answers that for
chores; Voice answers it for prose. They are the same claim about the same day,
which is why they are neighbours in the rail rather than a new band.

---

## 2. The corpus

### 2.1 Where samples live

```
~/Shifu/voice/
  samples/<ULID>-<slug>.md      # one file per sample, YAML frontmatter
  profile.md                    # derived; §3
```

**Deliberately not under `~/Shifu/vault/`.** `VaultStore.allNotes()` enumerates
every `.md` beneath the vault root and parses it as a `Note`; a sample dropped in
there would be read as a knowledge note with no `topic`, and while `Note.parse`
rejects it today, the vault's indexer, census and search would all have to grow a
special case to keep rejecting it. A sample is not a note — it is raw material —
so it gets its own root and the vault tree stays one kind of thing.

A sample file:

```yaml
---
id: 01K2B…                # ULID, sorts by when it was added
kind: voice_sample
title: Reply to the Datadog thread
source: paste             # paste | import
added: 2026-08-07T10:14:02Z
words: 412
---
Hey — short version: we're not going to take the enterprise tier this quarter…
```

`kind:` is present for the same reason the vault's notes carry one: so a future
reader can tell what it is holding without knowing which directory it came from.

### 2.2 Getting text in

Two doors, both explicit, both in the page:

- **Paste** — a sheet with a title field and a text box. The common case: one
  email, one Slack reply, one paragraph the user is proud of.
- **Import** — a file picker over `.txt`, `.md` and **`.pdf`**, multi-select.
  Each file becomes one sample titled from its filename. Files are judged one
  at a time: a short or unreadable one names itself in the notice and the good
  ones beside it still land.

Both run the text through `Redactor.redact` before it reaches disk (invariant 2).
A pasted email is *exactly* where a card number, an SSN or an API key turns up,
and a sample is the one kind of user text that is later shipped verbatim to a
model. Redaction at the door, not at the prompt: a `[REDACTED:CARD]` in the file
is visible to the user, who can then delete the sample; a redaction that happened
silently inside prompt assembly would not be.

#### PDFs, and why they need a cleanup pass

Most of what people have actually written *and kept* is a PDF — essays, letters,
reports, papers — so refusing the format refuses the corpus. The first draft of
this spec excluded it anyway, on the grounds that raw extraction "would put
layout artefacts into the corpus the metrics then measure as style." That
reasoning was right, and it is now the specification for the pass that lets PDFs
in (`VoiceImportText`, pure and in ShifuCore; `VoicePDF`, PDFKit and in ShifuApp
— the daemon links ShifuCore and has no business carrying a document renderer).

A PDF's text layer arrives one string per *visual line*, carrying everything the
typesetter added and the author never wrote. Each artefact corrupts a specific
measurement, which is why each is handled:

| Artefact | What it would become |
|---|---|
| page numbers | twenty one-word "sentences" in a twenty-page document — and the median sentence length is the one number the drafting prompt tells the model to aim at |
| running heads and feet | the author's most characteristic vocabulary, repeated once per page |
| hyphens at line ends | "migra" and "tion" — two words they never used |
| a line break every sixty characters | a column width read as a sentence length |
| ﬁ/ﬂ/ﬀ ligatures | "ﬁnished" measured as a different word from "finished" |

Running lines are found by what repeats at the very top or very bottom of half
the pages *while the body varies* — candidates are each page's first and last
content line and nothing else, because a surviving running head only skews the
vocabulary list where a wrongly dropped line loses real prose. Ligatures are
NFKC-normalised; em dashes and curly apostrophes have no compatibility
decomposition, so the two habits that matter most pass through untouched.

**Only PDF extraction calls the pass.** Pasted text and `.txt`/`.md` are already
prose, and reflowing them would destroy line breaks the author meant.

Two measured limits, both documented rather than papered over:

- **Paragraph breaks are only partly recoverable.** PDFKit's `page.string`
  reports neither the blank line nor the first-line indent that marked a
  paragraph — both arrive as a plain `\n`, indistinguishable from a wrap. So the
  break is inferred from line *length*, which works because a paragraph's last
  line almost always stops short of the margin. When it happens to fill the
  measure, two paragraphs merge, and no heuristic could do better — nothing in
  the extracted text distinguishes the cases. The cost is bounded to one reading
  (`medianParagraphSentences`) and one prompt line; sentence length, punctuation
  and vocabulary never depended on where a paragraph ended.
- **Single-column prose extracts cleanly; multi-column may interleave**, and
  heavily mathematical documents extract as rubble (a displayed matrix becomes a
  run of loose digits). Neither is worth chasing: a problem set is not a writing
  sample, and the user picks what they hand over.

### 2.3 What is refused, and why

**Harvesting the user's writing from captured screen text.** Shifu already holds
`observations.text` for every OCR'd window, and some of that text is prose the
user typed. Mining it would build the corpus with no work at all — and it is
refused, not deferred, because the read is unfixable: OCR of a screen cannot tell
what the user *wrote* from what they were *reading*. A mail client shows a reply
being composed above the quoted message being answered; a document shows the
user's paragraph beside the source they are quoting. A corpus half made of other
people's prose is worse than no corpus, because it is confidently wrong about the
one thing it exists to know, and the failure is invisible — the drafts just sound
like someone else. The user hands over samples, or there is no profile.

**OCR of a scanned PDF.** A PDF with no text layer is refused by name
(`IngestError.noTextLayer`) rather than run through Vision, and for the same
reason as above: what came back would be the *transcriber's* habits — its
line-break guesses, its punctuation, its confusions between similar glyphs —
measured as the user's style. A PDF whose text layer holds nothing but page
numbers and running heads counts as the same failure, because after the cleanup
pass it is.

**Empty and tiny samples.** Under `VoiceStore.minimumSampleWords` (25) a sample
is rejected at the door with a reason, not stored and ignored. So is a
password-protected PDF (`IngestError.locked`), which opens fine and then yields
nothing — its own case, because "unlock it" is a different instruction from "it
looks scanned".

---

## 3. The profile

`~/Shifu/voice/profile.md` — one derived document with two halves and a
fingerprint, rewritten whole whenever the corpus changes (§3.3).

### 3.1 Measured (`VoiceMetrics`, deterministic)

Pure statistics over the concatenated corpus. No model, no network, no database
— which makes it the half that can be unit-tested against a fixed string, and the
half the page can show on an install with the backend set to `off`.

What is measured, and why each one earns its line:

| Reading | Why it is style and not noise |
|---|---|
| median / mean sentence length | where the middle of the register sits — and *only* that; see §3.1a for why this was not enough |
| the quartiles, shortest and longest | the **shape** of the distribution, which is what the drafting prompt aims at |
| adjacent sentence gap | **burstiness**: how many words consecutive sentences differ by. The measure that matters most |
| share of sentences ≤6 words | whether short beats are in the repertoire at all — claimed only when it is really theirs |
| median paragraph length (sentences) | one-line paragraphs and six-line paragraphs are different writers |
| em-dash, semicolon, colon, parenthesis, ellipsis, exclamation, question rates (per 1,000 words) | punctuation is habit, and habit is the most imitable thing about a writer — someone who uses em-dashes for asides and never parentheses is instantly recognisable |
| contraction rate | the formality dial, and the one models get wrong most often |
| first-person and second-person rates | whether the writer says "I", "we", or neither, and whether they address the reader |
| average word length, long-word rate | Latinate versus plain diction |
| hedge rate, intensifier rate | "probably / sort of / I think" versus "absolutely / incredibly" — two different confidences |
| list-line and heading rates | whether they reach for bullets or write through |
| most frequent sentence openers | "But", "So", "The" — openers are a fingerprint people cannot hear in their own writing |
| recurring content words | the vocabulary they actually own |

`rules()` renders these as imperative, numeric prompt lines ("Median sentence:
14 words — keep most sentences near that"), because a number the model can aim
at survives a long prompt where an adjective does not.

### 3.1a Rhythm — the defect this section shipped with

The first version of this spec measured median, mean and longest sentence, and
told the model: *"Keep most sentences near the median and let a few run long —
that unevenness is the voice, do not smooth it out."*

That line was the worst thing in the design. It states one number and then asks
for uniformity around it, and a uniform cadence is the single clearest signal
that prose was not written by a person. The instruction did the opposite of what
its own second clause asked for, and the concrete number won.

It was found empirically, from outside: personalized drafts tripped an AI
detector while the samples they were built from did not. Detectors key on
*burstiness* — variance in sentence length and in word predictability — so what
they flagged was real, and it was this.

Measurement then disproved the belief the line rested on. On a real 3,117-word
corpus the median was 25 and the mean 26.6 — a gap of 1.6 words — while the
actual lengths ran from 4 to 69, quartiles at 19 and 33, with consecutive
sentences differing by **10.5 words on average**. The median-to-mean gap captures
skew, not spread. It says nothing about rhythm.

So the prompt now carries the distribution instead of its centre: quartiles and
both ends as numbers to reproduce, the adjacent gap in words, and the failure
mode named outright — *a draft where nearly every sentence is close to the median
is the clearest sign it was not written by them.* A model regresses to an even
cadence unless told the cadence itself is the mistake.

**A second defect surfaced while fixing the first**, and it is the reason
§3.1's floor exists. The corpus appeared to hold 7% one-word sentences — a
strong, imitable habit. Reading them showed what they actually were: numbered
list markers (`4.`, `3.`), punctuation the sentence split had stranded (`.`,
`.”`), a title block (`UTA Application`, `Jerry Fan`, `April 2026`), and one
Chinese quotation that whitespace-splitting counted as a single word. Two fixes:
a full stop directly after a bare number is no longer a terminator, and length
statistics are taken over **prose sentences only** — a sentence needs a letter
in it, and an unterminated one needs eight words to count. The true short-sentence
share is 0.9%, below the threshold at which the rule fires at all. Unfixed, the
profile would have instructed the model to write one-word sentences this author
does not write.

**Two floors, not one.** Below `VoiceMetrics.meaningfulWords` (400) the rates and
the absence claims are computed but never stated: "you never use semicolons" is a
lie drawn from forty words, and it is a lie the model will dutifully obey. But a
length *spread* is estimable from far less, so the rhythm rules ride a separate
gate — `rhythmSentences` (20). Which one binds first depends on the writer: at
nine words a sentence, twenty sentences arrive well under 400 words. Before the
split, a 300-word corpus was told nothing at all.

**Machine tells.** A short static list of words and phrases that read as
LLM-written (`delve`, `moreover`, `tapestry`, `it's important to note`, …) is
proscribed by name — but only the ones the corpus contains none of, and only
past the 400-word floor: "appears nowhere in their writing" is an absence
claim like the rest, whatever the sentence count says. The evidence
for the list is that they are tells; the corpus check is a safety valve, because
proscribing a word the writer genuinely uses would be the profile arguing with
its own samples. This addresses the *word-choice* half of what detectors measure.
The other half — token-level predictability — belongs to the model, not the
prompt (§9).

### 3.2 Described (`VoiceProfiler`, LLM)

One call, over the metrics plus as much of the corpus as the window allows, that
returns a short markdown **voice card** — Register, Sentences, Structure, Habits,
Avoid. Prose, because the things statistics cannot reach are exactly the things
worth saying: that the user opens on the conclusion, that they undercut their own
claims with a parenthetical, that they never sign off.

Rules in the prompt: describe only what the samples show; quote a short phrase as
evidence where it helps; no praise, no biography, no invented facts about the
person. `completeProse`, so a card that ran out of budget arrives trimmed to its
last whole line rather than being thrown away (`LLMText.salvage`).

The card is advice. The metrics are evidence. When they disagree the metrics win,
because they are the half that was measured — which is why `rules()` is rendered
*after* the card in the drafting prompt (§4.2).

### 3.3 When it rebuilds

Not on a timer. `VoiceStore.fingerprint()` is a stable hash of every sample's id
and content; the profile stores the fingerprint it was built from, and the
profiler runs only when the corpus's current fingerprint differs. Adding a
sample, editing one in a text editor, or deleting one all change it; an hourly
analyzer pass over an untouched corpus costs nothing.

Two entry points, both in `shifu-analyzer`:

- the hourly pass, so a sample added at 10:02 has a card by 11:00 without the
  user asking for anything;
- the start of every `--draft` run, so a user who adds a sample and immediately
  asks for a draft is drafted for from the new corpus, not the old one.

A profile that cannot be built (no backend, or the call failed) is not an error
state: the measured half stands alone, and §4 drafts from it.

---

## 4. Drafting

### 4.1 The request's life

`voice_drafts` is the only new table (`v28-voice-drafts`), and it is shaped like
`decks` for the same reason: **only `shifu-analyzer` may touch the network**
(invariant 1), so the app cannot draft — it can only write down that a draft was
asked for and launch the binary that can.

```
pending → drafting → ready
                   ↘ failed
```

- The app inserts the row `pending` (prompt redacted on the way in — it is a DB
  write like any other) and launches `shifu-analyzer --force --draft <id>`.
- The analyzer claims the row with a compare-and-set on `status`, exactly as
  `DeckStore.claimForBuild` does, so the interactive launch and the hourly drain
  cannot both draft the same request. A claim older than
  `VoiceDrafts.staleClaimMs` is takeable — the claimant crashed.
- Success writes `result` and `ready`. Failure writes `error` and `failed`.

`failed` is the one place this diverges from decks, and deliberately. A deck that
fails hands its claim back and retries silently on the next drain, because nobody
is watching. A draft has someone sitting in front of it: a request that silently
returned to `pending` would spin "Drafting…" forever with no reason given. The
hourly drain still picks up `pending` rows — the safety net for a launch that
never happened (no backend at request time, app quit mid-flight) — but a request
that was *tried* and failed says so.

### 4.2 The prompt

Assembled in `VoiceDrafter.prompt`, in this order:

1. the task framing and the honesty rules;
2. the described voice card (§3.2), when there is one;
3. the measured rules (§3.1), when the corpus clears the floor — **after** the
   card, so the numbers are the last word;
4. verbatim excerpts, newest first;
5. **the request, last.**

The request goes last for the reason `DeckBuilder.prompt` puts its budget line
there: everything above the first byte that differs between two prompts bills at
the provider's cache rate, and the request is the only part that changes between
two drafts on the same corpus. A user iterating on one piece of writing re-sends
an identical several-thousand-token preamble each time, and it should be cached.

The honesty rules matter as much as the samples. The model is told: imitate the
*voice*, never the *content* — the excerpts are handwriting samples, not source
material, and no name, number, company or claim may cross from an excerpt into
the draft. Without that line the first draft of a decline letter cheerfully reuses
the vendor from an unrelated sample.

### 4.3 Budget (invariant 7)

Excerpts are chosen by rendering the real prompt and growing it until it stops
fitting `contextWindowTokens - responseReserve(responseTokens)` — never by
sample count, which says nothing about size. Each excerpt is capped at
`VoiceDrafter.excerptCharCap` first, so one 40,000-word memoir cannot be the
whole corpus the model sees; the request itself is capped at
`VoiceDrafts.maxPromptChars` at the door, so a pasted document to rewrite cannot
push the preamble out of the window.

Newest-first is the v1 selection rule, and it is a real choice, not a placeholder:
the most recent writing is the closest to how the user writes *now*. Relevance
matching (embed the request, retrieve the nearest samples) is §9.

### 4.4 What comes back

`completeProse` with `VoiceDrafter.responseTokens` — a draft cut off two lines
from the end is still a draft worth reading, and the alternative is spending the
whole call to show an error. The result is redacted before it is stored (it is a
DB write) and shown with a Copy button, the same handoff the Radar uses: Shifu
does not send mail, and this is not the feature that starts.

History is capped at `VoiceDrafts.historyLimit` (20) — trimmed on insert, oldest
first. A drafting desk is not an archive; anything worth keeping is copied out.

---

## 5. UI — the Voice place

One page, `Place.voice`, in the `.signals` region directly under Radar. Two
columns, on the `NewDeckPage` pattern: **what you are asking for** on the left,
**what it knows about you** on the right.

- **Left — the desk.** A prompt box, a Draft button, and the last draft with its
  Copy button. Earlier drafts collapse to a list below it. While a request is
  `pending` or `drafting` the button reads "Drafting…" and is inert.
- **Right — the corpus.** Word count and sample count; the measured readings; the
  voice card; then the samples themselves, each removable. Add-by-paste and
  add-by-file at the foot.

Empty, the page is a `BlankSlate` saying what to hand over and why — not a
disabled form.

Without a backend the right column still shows its measurements and the Draft
button is replaced by the line the deck form uses ("A draft needs DeepSeek
(Settings)"). The page degrades to *a thing that measured your writing*, which is
worth arriving at; it never presents a button that cannot work.

No `Picker` and no `Menu` anywhere on it — menu-style pickers do not commit
selections on this machine, which is why `DropdownButton` exists.

---

## 6. Privacy & retention

- Samples are the user's files. Shifu writes them, lists them, deletes on
  request, and never rewrites one in place.
- Everything crossing the door is redacted (§2.2); so are draft prompts and draft
  results, because both are DB writes (invariant 2).
- Samples and drafts leave the machine only inside an LLM call the user opted
  into (§8), and only when they press Draft or the profiler rebuilds. `shifud`
  never reads `~/Shifu/voice/` and never will — it is not on the capture path.
- `~/Shifu` is already `0700`; the voice tree inherits it.
- Deleting a sample deletes the file. The profile is stale until the next rebuild
  (§3.3), which the deletion's fingerprint change guarantees.
- Drafts age out at 20 (§4.4). `shifu forget` semantics are unchanged — there is
  no observation, activity or task involved anywhere in this feature.

---

## 7. Invariants this feature is bound by

| Invariant | How it is met |
|---|---|
| 1 — no network in `shifud`; only the analyzer | the app writes a row and launches `shifu-analyzer --draft`; `VoiceDrafter` takes an injected `LLMBackend`, exactly as `DeckBuilder` does, so nothing network-shaped enters `ShifuCore` |
| 2 — redaction is one choke point before every DB write | `Redactor.redact` on sample import, on the draft prompt, on the draft result |
| 4 — pixels never persisted | not on the capture path at all |
| 7 — prompts are token-budgeted | excerpts sized by rendering with `LLMTokens.estimate`, against `contextWindowTokens - responseReserve(...)` |
| 8 — variables named with more than one character | — |

---

## 8. Phasing

**Phase 1 (this spec).** Corpus, measured profile, described profile, drafting
desk, the page. Exit criteria: a sample can be pasted and imported; the measured
readings appear with no backend configured; with one, a draft comes back in the
user's register; `make check` green.

**Phase 2.** Whatever the first week of real use asks for, and nothing else.

---

## 9. Deferred (log here, don't build — Minimalism rule)

- **Harvesting samples from captured screen text** — refused outright, see §2.3.
  So is OCR of a scanned PDF, for the same reason. Not the same kind of
  "deferred" as the rest of this list.
- **`.rtf` and `.docx` import** — `NSAttributedString` reads both in two lines
  and they would feed the same reflow pass as PDFs, so this is a minimalism call
  rather than a technical one. Add them the first time someone's writing is
  stuck in one.
- **Relevance-matched excerpts** — embed the request, retrieve the nearest
  samples (`SentenceEmbedder` already exists for vault search). Newest-first is
  §4.3's rule until someone can show it losing.
- **Multiple voices** — work versus personal, one profile each. One voice until
  the single-profile version is dull enough to complain about.
- **Drift over time** — the corpus is undated in effect; comparing this quarter's
  metrics against last year's is a chart nobody asked for yet.
- **Editing a draft in place, and feeding the edit back** — the strongest
  possible training signal (the diff between what the model wrote and what the
  user sent) and the biggest build. Worth doing after Phase 2 says the drafts are
  close enough to edit rather than discard.
- **Sampling controls (temperature, top-p) and model choice** — the remaining
  lever on the half of machine-ness a prompt cannot reach. Rhythm and word choice
  are promptable; a model's next-token *predictability* is not, and low-entropy
  diction is what detectors measure alongside burstiness. Deliberately not built:
  `LLMBackend.complete` would grow a parameter every conformer has to carry, for
  a gain nobody has measured here yet. The local tier is where to try it first —
  the user owns the server and the knob.
- **Sending anywhere** — Copy is the handoff, as on the Radar (design.md §6.2).
