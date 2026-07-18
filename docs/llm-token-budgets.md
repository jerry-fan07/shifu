# LLM token budgets

Incident write-up + the rule that came out of it (CLAUDE.md invariant 7).

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
- `AmbiguousClassifier.batches` chunks samples so each rendered prompt fits
  `contextWindowTokens − responseTokenReserve` (2,000 tokens reserved for the
  JSON response). Verdicts apply **per batch**: a mid-run failure keeps earlier
  updates and leaves the rest ambiguous for the next run.

`KnowledgeExtractor` (text capped at 2,500 chars) and `Radar.describe`
(≤10 one-line suggestions) produce bounded prompts that fit in 4k, so they
stay single-shot.

## Rule for new call sites

Any new prompt sent through `LLMBackend.complete` must fit the backend's
`contextWindowTokens`. If the prompt scales with data volume, chunk it with a
token-aware batcher (see `AmbiguousClassifier.batches`), never by item count.
Regression coverage lives in `AmbiguousClassifierTests`
(`runSplitsAcrossSmallContextWindow` forces multi-batch behavior through a
2,600-token mock window).
