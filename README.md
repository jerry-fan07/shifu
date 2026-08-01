# Shifu

> *Shifu lies awake, quiet but observant by your side.*

Most of a working day evaporates. Not the meetings or the milestones — the
connective tissue between them: the forty minutes that went somewhere, the
document you understood deeply and then forgot you ever read, the same dreary
sequence of clicks performed for the hundredth time without anyone noticing it
had become a ritual. Attention leaves no residue. By evening the day has
already begun rounding itself off to a story.

**Shifu (师傅: mentor, master in martial arts)** is a quiet observer that keeps the residue. It sits on your Mac, watches
the screen the way a patient teacher watches a student — not to judge, to
remember — and help you do four things:

1. **Understand your productivity (and yourself)** with an honest account of where the hours actually
   went, assembled from evidence rather than recollection.
2. **Recall and return to** the facts and ideas you encountered, distilled into
   a beautiful render of Markdown-style notes and a searchable vault.
3. **Remember everything** with automatically generated flashcards (Anki FSRS algorithm), so
   what you read once becomes internalized forever with the magic of spaced repetition.
4. **An efficiency radar** to catch your repetitive workflows, and helping you automate them.

Everything it captures stays on your Mac. What leaves — if you allow anything
to leave at all — is narrow, redacted, and yours to switch off. The full
specification lives in [design.md](design.md); the privacy model has its own
section below, because for software like this the privacy model *is* the
product.

## Install

Requires an Apple Silicon Mac on macOS 14 or newer.

1. Download `Shifu-x.y.z.dmg` from the
   [latest release](https://github.com/jerry-fan07/shifu/releases/latest),
   open it, and drag **Shifu** to Applications. The app is notarized —
   Gatekeeper will verify rather than warn.
2. Launch it. Onboarding walks through the four things worth knowing before a
   screen observer starts observing: what is captured, the two permissions,
   what is never read, and whether a model may be consulted.
3. Grant the two permissions in **System Settings → Privacy & Security**:
   - **Accessibility** — window titles and visible text, the cheap capture path
   - **Screen Recording** — the screenshot→OCR fallback for apps that expose
     no accessible text; without it Shifu still works on metadata alone
4. The capture daemon registers itself as a Login Item (one toggle in
   **System Settings → General → Login Items**) and starts keeping the ledger.

The proof that everything is wired: the ledger begins filling. Give it an hour.

### Choosing a mind (or none)

Rules alone can classify the obvious. Naming what a stretch of time *meant* —
"booking flights for the Denver trip", not "airline website" — takes a model.
Onboarding offers three positions, and **off is the default**:

- **Rules only** — no AI, nothing ever leaves the Mac.
- **Shifu Cloud** — no key, no account: redacted, post-exclusion text samples
  go to Shifu's server, which forwards them to DeepSeek (an AI provider based
  in China) and holds the credentials.
- **Own API key** — the same samples go straight to DeepSeek with your key,
  never through Shifu's server. `deepseek-v4-flash` runs the high-volume
  stages, `deepseek-v4-pro` the judgment-heavy grouping; both overridable in
  Settings, and any OpenAI-compatible endpoint works via
  **Settings → Analysis → Endpoint**.

Change your mind anytime in **Settings → Analysis**.

## CLI

The `shifu` command ships inside the bundle at
`/Applications/Shifu.app/Contents/MacOS/shifu` — symlink it onto your PATH:

```sh
ln -s /Applications/Shifu.app/Contents/MacOS/shifu /usr/local/bin/shifu
```

```
shifu log [days]        today's observation trace
shifu status            pause state, focus mode, today's counts
shifu pause 1h          pause capture (tears down observers, doesn't just gate)
shifu resume
shifu focus on|off      Focus Mode: glow-pulse nudges when off-task
shifu review            spaced-repetition session over due notes
shifu forget last 2h    delete a time range (raw + derived)
shifu forget app <id>   purge one app's data
shifu forget all --yes  delete everything
shifu encrypt           migrate the database to SQLCipher (key in Keychain)
```

`shifu-analyzer` runs hourly from the daemon (on AC power); run it by hand with
`--force`, `--rebuild`, `--digest`, or `--radar`.

## The privacy model

A screen observer lives or dies on trust, so the guarantees are structural —
enforced by architecture and CI, not by promises:

- **No keystroke capture, ever.** Only visible text and metadata.
- **Pixels are never persisted** — screenshots exist in memory for one OCR
  call, then they're gone.
- **Exclusions before capture, not filtering after**: password managers,
  banking and health sites, and private browser windows are never read. They
  count only as opaque private time.
- **One redaction choke point**: card numbers, SSNs, and secret-shaped strings
  are stripped before anything touches disk.
- **The daemon cannot speak.** `shifud` links no networking symbols — verified
  by symbol inspection in CI (`scripts/check-no-network.sh`). Only the
  analyzer may reach the network, only to the configured LLM endpoint, and
  only after you opt in. The opt-in is explicit, never preselected, and
  defaults to off; what is sent is derived, redacted, post-exclusion text —
  never pixels, never raw captures.
- **Pause means torn down**, not muted: pausing removes the observers rather
  than gating their output, and the menu bar glyph says so unambiguously.
- Raw text expires after 14 days (configurable 1–90); the ledger and confirmed
  notes persist.
- **Encryption at rest (opt-in)**: `shifu encrypt` migrates the database to
  SQLCipher; the key lives in your login Keychain. Stop the daemon during
  migration.

## Data layout

Your data is files in your home folder, not a service:

```
~/Shifu/
  shifu.db      SQLite (WAL): observations, activities, rules, suggestions, settings
  vault/        Markdown knowledge notes — open it in Obsidian
  digests/      daily digest markdown
  logs/         daemon logs
  bin/          dev installs only — bundled builds migrate this away
```

## Development

- **[ARCHITECTURE.md](ARCHITECTURE.md)** is the orientation doc: the pipeline,
  where each concept lives in code, the consolidated schema, and how the
  privacy invariants are enforced. [design.md](design.md) is the spec;
  [implementation.md](implementation.md) the phase plan.
- `make check` (build + tests + SwiftLint + privacy invariants) must be green
  before every commit; a perf-budget regression (`make perf`) blocks like a
  test failure (<0.5% avg CPU, <80 MB RSS for the daemon).
- Targets: `ShifuCore` (all testable logic), `shifud` (capture daemon),
  `shifu-analyzer` (batch worker, the only binary allowed near the network),
  `shifu` (CLI), `ShifuApp` (desktop app + menu bar).

Dev installs, which scatter binaries instead of bundling them:

```sh
./scripts/install-daemon.sh     # release build → ~/Shifu/bin + LaunchAgent
./scripts/install-app.sh        # full bundle → /Applications/Shifu.app, dev-signed
```

Both sign with your first codesigning identity (override with
`SHIFU_CODESIGN_IDENTITY`) because macOS keys TCC grants to the code
signature — an ad-hoc signature changes every build and silently orphans the
grants. If capture degrades to metadata-only after a reinstall, remove the
stale permission entries, re-add `~/Shifu/bin/shifud`, and restart:

```sh
launchctl kickstart -k "gui/$(id -u)/com.shifu.shifud"
```

Rebuilding to see a change in the running app: [start.md](start.md).

### Cutting a release

```sh
scripts/release.sh                    # bundle → Developer ID sign → notarize → staple → DMG
SHIFU_VERSION=0.2.0 scripts/release.sh
```

Requires a `Developer ID Application` identity in the keychain (the script
refuses anything else — a development certificate fails notarization) and a
`notarytool` keychain profile named `shifu`. `--no-notarize` builds a locally
testable DMG. Output lands in `dist/`; publish with
`gh release create vX.Y.Z dist/Shifu-X.Y.Z.dmg --title "Shifu X.Y.Z" --generate-notes`.

The hosted backend is a Cloudflare Worker in [server/](server/README.md) —
the DeepSeek key lives there as a secret, never in the client.
