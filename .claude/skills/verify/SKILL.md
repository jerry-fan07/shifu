---
name: verify
description: Drive ShifuApp against real data and capture what it draws. Use when verifying a change to Sources/ShifuApp — the UI has no other observable surface on this machine.
---

# Verifying ShifuApp

`screencapture` returns black without a Screen Recording grant, and
`ImageRenderer` refuses to lay out a `ScrollView`. The only way to see what
the app draws is to host it in an offscreen `NSWindow` and `cacheDisplay` the
layer tree. `Tests/ShifuAppTests/WindowShots.swift` does that — it is a
camera, not an assertion suite, and it no-ops unless `SHIFU_SHOTS` is set.

## Run it

```bash
# A copy, not ~/Shifu: the store opens the database read-write.
rm -rf /tmp/shifu-verify && mkdir -p /tmp/shifu-verify
cp ~/Shifu/shifu.db* /tmp/shifu-verify/ && cp -R ~/Shifu/vault /tmp/shifu-verify/

SHIFU_SHOTS=/tmp/shifu-shots SHIFU_HOME=/tmp/shifu-verify \
    swift test --filter WindowShots
```

One PNG per `Place`, plus a theme page and a task page (the two screens that
only exist behind a row). **Read the PNGs.** A green test here means the
renderer didn't crash, nothing more.

## Probes worth running every time

| Probe | How |
|---|---|
| Empty install | `SHIFU_HOME=$(mktemp -d)` — blank slates, no counts, no crash |
| Minimum window | `SHIFU_SHOT_WIDTH=960` — the `minWidth` the shell declares |
| Below the fold | `SHIFU_SHOT_HEIGHT=2600` — the harness can't scroll; a taller film is the only way to see a long page's tail |
| Dark mode | already covered: Timeline and Deck render dark, the rest light |

## What real data breaks that mock data doesn't

The dogfood ledger is the point — these were all invisible until it was
pointed at real rows:

- **Hundreds of tiny blocks.** A day is ~200 blocks of 20–60 seconds. Anything
  drawn per block becomes a barcode; `LedgerShapes.ribbon` resamples into
  `columns` slots and merges neighbours for exactly this reason.
- **Blocks that overlap midnight.** `labeledActivities` returns anything
  *overlapping* the window, so a session that began at 23:00 yesterday arrives
  with yesterday's timestamp. Clip before deriving anything from it.
- **Sub-minute durations.** `TimeBreakdown.duration` prints seconds below a
  minute; a column of "0m" is what happens otherwise.
- **12-hour locales.** "10:11 AM" is much wider than the design's "18:22".
  Every timestamp column needs `.lineLimit(1)` and room.
- **Long real names.** Topics and task names run to 60 characters where the
  design mocked 12.

## The drop-down needs its own camera

Every "pick one of these" is a `DropdownButton`, and its panel lives in a
child window — so it is never in a `WindowShots` composite, whatever is open.
`DropdownShots` hosts a bench, drives a **real click** through `NSApp`, asserts
the panel opened, and writes the composite:

```bash
SHIFU_SHOTS=/tmp/shifu-shots swift test --filter DropdownShots
```

It has to activate this process — expect the focus to jump for ten seconds.
Two such tests can't share a process: each pumps the runloop, and the second
one never runs. Keep it one test.

## Measuring, not just looking

- **Is a mark at the right place?** Eyeballs miss one-hour offsets. Probe the
  PNG per-pixel with `NSBitmapImageRep`, calibrate px-per-hour from the pitch
  of *interior* axis labels (edge labels are inset), and cross-check the
  answer against a replay over the dogfood copy.
- **CPU:** `top` reports ~0% for an app that is not truly frontmost — activate
  the process (as `DropdownShots` does) and measure while it owns the screen,
  or the number is fiction.
- **Draw-pass timing:** `ImageRenderer.nsImage` is deferred — timing it times
  nothing. Render into a `CGContext`, or time `cacheDisplay` itself.
- **When a pass is slow, suspect layout before logic.** The 120 ms hover of
  2026-07 was `ViewThatFits` re-laying the block head on every commit, not
  the body compute; pre-measuring text with `NSFont` cured it
  (`SummaryLine`).

## Gotchas

- The harness freezes Core Animation and starves `Task.sleep`, so it cannot
  verify animation timing — only static layout. (Related, in the live app: a
  replayed 0→1 `withAnimation` coalesces into no animation at all —
  retriggered effects need `KeyframeAnimator(trigger:)`.)
- **The harness rewrites the vault it is pointed at.** `store.refresh()` runs the
  work-note compile, and a day whose blocks differ from the note's
  `content_hash` is rewritten *without* its LLM prose — so the copy's newest
  day-notes lose their narrative after the first run, and the task page
  photographs as a head with nothing under it. That is correct behaviour on a
  stale copy; `WindowShots.unrollableTask` picks a subject that survives it.
- **Only state set *synchronously* in `onAppear` reaches the film.** A read
  deferred by `Task { @MainActor }` or `DispatchQueue.main.async` resolves —
  the run loop is pumped for a second — but the redraw it schedules never
  arrives, so the shot shows the pre-read view with no sign anything is
  missing. `DayHistoryRow` reads its work note in the appearing pass for this
  reason. If a section photographs empty, suspect the hop before the data.
- Interaction (clicks, hover, keyboard) is **not** covered by `WindowShots`.
  `onHover` fires from wherever the real mouse happens to be, which shows up
  as a random row looking selected. A click only lands if the process is
  active *and* the event goes through `NSApp.postEvent` + `nextEvent` —
  `window.sendEvent` never reaches a SwiftUI gesture (`DropdownShots.click`).
