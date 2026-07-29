# LLM token budgets

Incident write-up + the rule that came out of it (CLAUDE.md invariant 7).

> **Status 2026-07-28:** the Foundation Models backend described below has
> since been removed — DeepSeek is the only backend (design.md §4.2), capped
> at 60k tokens in `DeepSeekBackend.contextWindowTokens`. The rule stands
> unchanged: size every prompt with `LLMTokens.estimate` against the
> backend's window, never by item count.

## What happened (2026-07-17)

Every `shifu-analyzer` run on a machine using the on-device backend failed the
tier-2 pass with:

```
llm (foundation-models) failed, blocks stay queued: exceededContextWindowSize
(… Provided 6,165 tokens, but the maximum allowed is 4,096.)
```

`AmbiguousClassifier` batched up to 20 blocks — each with window titles plus a
600-char text sample — into a single prompt, sized by **item count only**.
Apple Foundation Models has a hard 4,096-token context window shared by prompt
*and* response, so the prompt overflowed and the same blocks re-failed forever
on retry. Claude (200k window) never hit this, which is why it survived until
the first metadata-rich run on the FM backend.

## The fix

- `LLMBackend` declares `contextWindowTokens` (default 200k;
  `FoundationModelsBackend` overrides to 4,096).
- `LLMTokens.estimate` gives a conservative prompt-size estimate
  (≈3 UTF-8 bytes per token) so dense OCR text can't out-tokenize the guess.
- `LLMTokens.batches(_:budget:render:)` is the shared greedy batcher: grow a
  batch, render the real prompt, split when the render exceeds
  `contextWindowTokens − responseTokenReserve` (2,000 tokens reserved for the
  JSON response). `AmbiguousClassifier.batches` and `Radar.batches` are one
  line each over it. Verdicts apply **per batch**: a mid-run failure keeps
  earlier updates and leaves the rest for the next run.

`KnowledgeExtractor` (text capped at 2,500 chars) produces a bounded prompt
that fits in 4k, so it stays single-shot.

**`Radar.describe` lost its exemption in 2026-07** (design.md §6.2). It used
to send ≤10 one-line patterns; it now sends up to 12 *dossiers*, each carrying
day-log lines, sampled window titles and a 300-char text sample, under a fixed
framing and tool catalog that is itself ~1k tokens. So it batches like the
classifier, through the same `LLMTokens.batches`, against a reserve of 2,500 —
larger than the classifier's, because each verdict carries prose rather than a
handle and a number.

## Rule for new call sites

Any new prompt sent through `LLMBackend.complete` must fit the backend's
`contextWindowTokens`. If the prompt scales with data volume, chunk it with a
token-aware batcher (`LLMTokens.batches`), never by item count.
Regression coverage lives in `AmbiguousClassifierTests`
(`runSplitsAcrossSmallContextWindow` forces multi-batch behavior through a
2,600-token mock window) and `RadarTests`
(`describeSplitsBatchesUnderSmallContextWindow`, which sizes its mock window
from the rendered framing so the test can't drift when the prompt grows).
