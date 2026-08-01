---
name: ship
description: Install or release Shifu.app, or diagnose "the app looks old / my change is missing" — /Applications/Shifu.app, the LaunchAgent daemon, and ~/Shifu are machine-global and shared by every workspace. Check provenance before debugging logic.
---

# Shipping Shifu

## One install, many workspaces

Several worktrees feed one `/Applications/Shifu.app`, one registered daemon,
one `~/Shifu`. "My change isn't there" or "the UI looks old" usually means a
*different branch* ran `install-app.sh` more recently — establish who built
the installed app before touching logic:

```bash
defaults read /Applications/Shifu.app/Contents/Info.plist CFBundleShortVersionString  # marketing version (ShifuCore fallbackVersion)
defaults read /Applications/Shifu.app/Contents/Info.plist CFBundleVersion             # git commit count of the building branch
git rev-list --count HEAD                                                             # this branch, for comparison
stat -f '%Sm' /Applications/Shifu.app/Contents/Info.plist                             # when it was assembled
launchctl print "gui/$(id -u)/com.shifu.shifud" | grep -m1 program                    # which shifud is actually live
```

Commit counts can collide across branches — read them together with the
assembly time.

## Two ways in, one bundle recipe

Both paths assemble through `scripts/bundle-app.sh` — all four executables
as siblings in `Contents/MacOS` (that is how `ShifuPaths.helper` finds
them), GRDB in `Contents/Frameworks`, version stamped from
`ShifuCore.fallbackVersion`, build number = git commit count — so the two
installs cannot differ in layout, only in signing:

| | `scripts/install-app.sh` | `scripts/release.sh` |
|---|---|---|
| Purpose | dev install into /Applications | notarized, stapled `Shifu-<v>.dmg` in `dist/` |
| Identity | any stable cert (keeps TCC grants across rebuilds) | Developer ID only — it refuses Apple Development certs, which fail notarization |
| Notarization | none | notarytool keychain profile `shifu` (`SHIFU_NOTARY_PROFILE`); `--no-notarize` for a signed dry run |

## Traps

- **First launch of a bundled app deletes `~/Shifu/bin`.**
  `DaemonService.migrateLegacyInstall` boots out the legacy LaunchAgent and
  removes the plist and the scattered dev binaries; user data beside `bin/`
  is untouched. Expected, not a bug — `scripts/install-daemon.sh` recreates
  the dev layout if you need it back.
- **Changing the signing identity resets TCC once.** ad-hoc/dev ↔
  Developer ID changes the app's identity, so expect to re-grant Screen
  Recording and Accessibility on the next launch. Losing AX silently costs
  ~80% of captures and ~96% of URLs — check grants after any identity
  change, don't wait for the ledger to thin out.
- **Never mutate a signed bundle in place.** `install_name_tool` or any file
  edit invalidates the signature, and arm64 answers a bad signature with
  SIGKILL at launch. Copying a bundle keeps its now-stale signature too:
  `rm -rf` the destination, copy fresh, then re-sign — nested binaries
  first, the bundle itself **last** (`codesign -s -` is enough for a /tmp
  verify copy).
