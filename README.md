# RunClosed

A macOS menu-bar utility for people who dock a laptop to external displays:
toggle displays on/off, dim the ones macOS can't dim, pick resolutions, and
keep the machine awake with the lid closed — from one popup with real toggles.

Formerly `DisableScreen` (the Python app in this repo's history); the product
was rewritten in Swift and renamed. The Python implementation is kept in-tree
as the audited baseline (see [Repository layout](#repository-layout)).

## Features

- **Toggle each display on/off** from a popup switch (SkyLight under the hood).
  The last active display is protected: its switch is greyed out.
- **Brightness slider** per display — native brightness for the built-in panel,
  a software-dim overlay for external monitors whose DDC path macOS ignores on
  Apple Silicon.
- **Resolution picker** listing the modes reported by CoreGraphics, with a
  read-back that verifies the mode actually changed.
- **Keep awake with lid closed** — flips the `pmset disablesleep` flag with an
  ownership model (see [Safety model](#safety-model)).
- **Open at login** via `SMAppService`.
- Localized: **English** (base) and **French**.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon (Intel compiles, untested)
- Xcode 16+ / Swift 6 toolchain (build only)
- No third-party dependencies

## Build

```bash
bash scripts/build-runclosed-app.sh
# → build/RunClosed.app
```

Signing: the script ad-hoc signs by default (`-`). For the login-item approval
flow and distribution, pass a Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  bash scripts/build-runclosed-app.sh
```

Test:

```bash
swift test        # 295+ assertions across Core / MacSystem / Persistence / UI logic
```

## Install

```bash
cp -R build/RunClosed.app /Applications/
open /Applications/RunClosed.app
```

The app lives in the menu bar (no Dock icon). Left-click opens the popup,
right-click opens a small menu (Refresh / Display Settings / Quit).

### Optional: passwordless lid control

The "keep awake with lid closed" toggle writes `pmset -a disablesleep`. Add a
sudoers drop-in so the app can do it without a prompt:

```bash
sudo tee /etc/sudoers.d/runclosed-pmset >/dev/null <<'EOF'
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF
sudo chmod 0440 /etc/sudoers.d/runclosed-pmset
```

Without this rule the toggle fails fast and honestly (it never prompts — the
app calls `sudo -n`, and the read-back is what decides success).

State lives under `~/Library/Application Support/RunClosed/`:

```
leases.json             # bounded keep-awake leases (CLI wrappers)
owned_displays.json     # displays we disabled (re-enabled at next launch)
owned_lid.json          # lid flag ownership record (boot-scoped)
```

## Safety model

This app mutates global system state (display topology, a root-owned power
flag), so the invariants are the interesting part:

- **Read-back decides.** A native call returning 0 is not success; the
  observable outcome is. All mutations carry a typed result
  (`verified` / `failed` / `unknown`).
- **UNKNOWN ≠ OFF.** An unreadable state is never rendered or treated as OFF.
- **Ownership.** The lid flag is restored on quit only when we set it on this
  boot, proven by a persisted record + read-back. A flag owned by another boot
  is kept as `recoveryPending` and never silently flipped (fail-closed).
- **Last-display guard.** Disabling the only active display is refused at the
  moment of the effect, not at render time.
- **One target per command.** A brightness command for display A never touches
  display B.

## Repository layout

```
Sources/
  RunClosedCore/         # pure logic: policies, models, lease engine (no AppKit)
  RunClosedMacSystem/    # macOS surfaces: CoreGraphics, SkyLight, pmset, SMAppService
  RunClosedPersistence/  # on-disk state (atomic writes, schema-versioned)
  RunClosedApp/          # presentation logic (view-model + text renderer)
  RunClosedMenuBar/      # the menu-bar app (AppKit)
  RunClosedHelper*/      # privileged LaunchDaemon skeleton (registration only)
  runclosed/             # CLI: status, displays, doctor, run, disable/enable,
                         #      lid-stay-awake, restore, login-item, helper
tests/                   # Swift test suites
main.py, launcher.m,     # legacy Python app (audited baseline, kept in-tree)
build.sh, test_e2e.py
docs/mutation-inventory.md  # every external state mutation of the legacy app
DECISIONS.md             # architecture decision records (ADR table)
PROGRESS.md              # tranche-by-tranche delivery log
TEST_RESULTS.md          # what was tested, with commands and outcomes
```

## Known limitations

- Display disable/enable uses the **private SkyLight API**
  (`SLSConfigureDisplayEnabled`). Not App Store-submittable; fine for direct
  distribution. Notarization does not change this.
- The two-display enable/disable path has not been exercised end-to-end on
  hardware with a single screen (the last-display guard is what runs there).
- External brightness is a **software overlay**, not DDC. The UI says so.
- The privileged helper daemon ships as a registration skeleton (no XPC yet);
  the day-to-day app uses `sudo -n pmset` + the sudoers rule instead.

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Benjamin Belaga.
