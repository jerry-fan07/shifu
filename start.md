# Rebuilding Shifu to see your changes

Shifu is two installable pieces, rebuilt by two scripts:

| What you changed | Rebuild with |
|---|---|
| `ShifuApp` (menu bar UI, dashboard, `LedgerStore`) | `./scripts/install-app.sh` |
| `shifud`, `shifu-analyzer`, `shifu` CLI, or `ShifuCore` logic they use | `./scripts/install-daemon.sh` |

`ShifuCore` is linked into everything — if you changed it, rebuild whichever
piece(s) consume the code you touched (when in doubt, run both scripts).

## 1. Verify the change builds

```sh
make check
```

Builds all targets, runs unit tests, SwiftLint, and the privacy invariants.
Must be green before installing (and before every commit).

## 2. Rebuild the menu bar app

```sh
# Quit the running app first: click the eye icon in the menu bar → Quit
./scripts/install-app.sh
open /Applications/Shifu.app        # or ~/Applications/Shifu.app if /Applications isn't writable
```

The script builds `ShifuApp` in release mode, bundles it as `Shifu.app`
(with GRDB.framework and the icon), signs it, and installs it. The script's
last lines print the exact path it installed to. The app is menu-bar only
(no Dock icon) — look for the eye.

## 3. Rebuild the daemon, analyzer, and CLI

```sh
./scripts/install-daemon.sh
```

This builds `shifud`, `shifu-analyzer`, and the `shifu` CLI in release mode,
copies them to `~/Shifu/bin/`, and restarts the `com.shifu.shifud`
LaunchAgent — no manual restart needed.

Note: the app and shifud both spawn the analyzer from `~/Shifu/bin/`, so
**changes to `shifu-analyzer` only take effect after running
`install-daemon.sh`**, even though the app triggers it (e.g. the
refresh-on-menu-open analysis run).

## 4. Check it's running

```sh
shifu status                                  # if ~/Shifu/bin is on your PATH
launchctl print gui/$(id -u)/com.shifu.shifud # daemon state
tail -f ~/Shifu/logs/shifud.log               # daemon output
```

## Troubleshooting

- **Permission prompts after rebuild** (Accessibility / Screen Recording):
  TCC grants are tied to the code signature. Both install scripts sign with
  your first codesigning identity (override with `SHIFU_CODESIGN_IDENTITY`);
  if no identity is found they warn and grants break on every rebuild.
- **App doesn't reflect your change**: make sure you quit the old instance
  before `open`-ing the new one — macOS won't relaunch an already-running app.
- **Stale build weirdness**: `make clean` then rebuild.
- **Uninstall the daemon**: `./scripts/install-daemon.sh --uninstall`
  (leaves data in `~/Shifu` intact).
