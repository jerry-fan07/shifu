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

## Gotchas

- `Menu` + `.menuStyle(.borderlessButton)` **keeps only the label's text** —
  padding, borders, and extra views inside the label are dropped. Decorate the
  `Menu` itself, from outside. (Same family as the macOS 26 menu-`Picker` bug
  that made every "pick one of these" control a `Menu` of `Button`s.)
- The harness freezes Core Animation and starves `Task.sleep`, so it cannot
  verify animation timing — only static layout.
- Interaction (clicks, hover, keyboard) is **not** covered. `onHover` fires
  from wherever the real mouse happens to be, which shows up as a random row
  looking selected.
