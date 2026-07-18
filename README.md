# Shifu

> *Shifu watches you work.*

A local-first, always-on macOS screen observer that turns what's on your screen into:

1. **Productivity ledger** — automatic, honest accounting of where your time went
2. **Knowledge vault** — facts you encountered, distilled into Markdown notes and
   reviewed on an FSRS spaced-repetition schedule
3. **Efficiency radar** — detection of repetitive workflows worth automating

Everything stays on your Mac. See [design.md](design.md) for the full specification.

## Requirements

- macOS 14+ (Apple Silicon primary), Xcode 16+ toolchain
- On-device LLM features use Apple Foundation Models (macOS 26+); cloud analysis
  via the Claude API is strictly opt-in

## Install

```sh
make check                      # build + tests + lint + privacy invariants
./scripts/install-daemon.sh     # builds release, installs the LaunchAgent
```

Then grant permissions in **System Settings → Privacy & Security** to
`~/Shifu/bin/shifud`:

- **Accessibility** — window titles + visible text (the cheap capture path)
- **Screen Recording** — screenshot→OCR fallback for apps with no accessible text

The install script code-signs the binaries with your first codesigning identity
(override with `SHIFU_CODESIGN_IDENTITY`). This matters: macOS keys TCC grants
to the code signature, and the default ad-hoc linker signature changes on every
build — after a reinstall the toggles still show ON but reference the old
binary, and shifud silently degrades to metadata-only capture
(`logs/shifud.log` shows "permission missing" warnings). A certificate-based
signature keeps grants valid across rebuilds. If grants were made against an
unsigned build, remove the stale entries (**–**), re-add `~/Shifu/bin/shifud`,
and restart the daemon:

```sh
launchctl kickstart -k "gui/$(id -u)/com.shifu.shifud"
```

Run the menu bar app for the dashboard, review sessions, and onboarding:

```sh
swift run ShifuApp
```

## CLI

```
shifu log [days]        today's observation trace
shifu status            pause state, work mode, today's counts
shifu pause 1h          pause capture (tears down observers, doesn't just gate)
shifu resume
shifu work on|off       Work Mode: glow-pulse nudges when off-task
shifu review            spaced-repetition session over due notes
shifu forget last 2h    delete a time range (raw + derived)
shifu forget app <id>   purge one app's data
shifu forget all --yes  delete everything
shifu encrypt           migrate the database to SQLCipher (key in Keychain)
```

`shifu-analyzer` runs hourly from the daemon (on AC power); run it by hand with
`--force`, `--rebuild`, `--digest`, or `--radar`.

## Privacy model

- **No keystroke capture, ever.** Only visible text and metadata.
- **Pixels are never persisted** — screenshots exist in memory for one OCR call.
- **Exclusions before capture**: password managers, banking/health sites, and
  private browser windows are never read; they count only as opaque private time.
- **Redaction choke point**: cards, SSNs, and secret-shaped strings are stripped
  before anything touches disk.
- **No network in the daemon** — enforced by symbol inspection in CI
  (`scripts/check-no-network.sh`). Only the analyzer may talk to the network,
  and only when cloud analysis is switched on.
- Raw text expires after 14 days; the ledger and confirmed notes persist.
- **Encryption at rest (opt-in)**: `shifu encrypt` migrates the database to
  SQLCipher (via DuckDuckGo's GRDB+SQLCipher build); the key lives in your
  login Keychain. Stop the daemon during migration. Each binary prompts once
  for Keychain access; because `install-daemon.sh` signs with a stable
  identity, that approval survives rebuilds.

## Data layout

```
~/Shifu/
  shifu.db      SQLite (WAL): observations, activities, rules, suggestions, settings
  vault/        Markdown knowledge notes — open it in Obsidian
  digests/      daily digest markdown
  logs/         daemon logs
  bin/          installed binaries
```

## Development

- `make check` must be green before every commit; a perf-budget regression
  (`make perf`) blocks like a test failure (<0.5% avg CPU, <80 MB RSS).
- Targets: `ShifuCore` (all testable logic), `shifud` (capture daemon),
  `shifu-analyzer` (batch worker), `shifu` (CLI), `ShifuApp` (menu bar + dashboard).
- Phase plan and verification gates: [implementation.md](implementation.md).
