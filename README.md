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
- **Timed sessions** — pick 1 h / 2 h / 4 h / 8 h (or leave the switch
  indefinite) and the row shows "Until 14:30 · 2 h 41 left", with the remaining
  time next to the menu-bar icon. "+30 min" extends, "End" stops. Deadlines are
  measured on the continuous clock, which keeps counting while the Mac sleeps,
  so an overnight session ends when its time is up rather than when you next
  look at it. A low-battery release pauses the session instead of cancelling
  it (ADR 023). CLI: `runclosed session start --for 2h | extend 30m | end |
  status --json`.
- **Low-battery guard** — on battery, warns at 20 % and, at 10 % (or ≤ 10 min
  left), turns the lid stay-awake flag off and puts the Mac to sleep so
  hibernation keeps every process; re-enables it on AC above 15 %. Never acts
  on AC. A flag RunClosed set on a previous boot (it survives restarts) is
  released as an emergency; a flag set by another tool is never touched
  (ADR 022). Kill switch:
  `defaults write com.benjaminbelaga.RunClosed lowBatteryGuardEnabled -bool false`.
- **Lid-close actions** — during a keep-awake session, with the lid closed
  **and no external display attached**, mutes the default audio output and (on
  a separate switch) pauses Slack, Discord and WhatsApp. Off by default;
  switched on in the menu bar's right-click menu. A docked Mac with the lid
  closed is never touched. Every effect is journaled before it is applied and
  the undo is verified by readback, so nothing is left muted or frozen; an app
  whose process id was recycled is left paused and listed "to verify" rather
  than resumed blindly. Screen brightness and keyboard backlight are
  deliberately **not** included yet: they need a proof-of-undo that only the
  hardware measurement can provide (ADR 026). Kill switch: the right-click
  menu, or `defaults write com.benjaminbelaga.RunClosed lidCloseActions -bool
  false`, which the next tick reads as "undo whatever is journaled". CLI:
  `runclosed lid-close status --json | simulate`.
- **Recovery backstop** — a per-user LaunchAgent runs `runclosed-cli recover
  --backstop` every 60 s and takes only protective actions while the app is not
  running: a session whose deadline passed is ended, and at critical battery
  the lid flag is released and the Mac sleeps. It never turns the flag ON and
  never performs the low-battery re-arm, so it cannot wake the Mac unattended.
  Registered via `SMAppService.agent(plistName:)`; approval in System Settings →
  Login Items, with a one-click link in the popup while it is pending. CLI:
  `runclosed backstop status --json | register | login-items | unregister`
  (ADR 024).
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
swift test        # 438 tests across Core / MacSystem / Persistence / UI logic
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
session.json            # current keep-awake session: id, boot, deadlines, pause
low_battery_guard.json  # guard latch (notifications, pending re-arm)
low_battery_audit.jsonl # one line per low-battery mutation
recovery_audit.jsonl    # one line per recovery-backstop action or failure (never per no-op)
backstop_heartbeat.json # proof the recovery agent RUNS: last run time, boot, exit code
lid.lock                # cross-process lock serialising every lid writer
app.lock                # held while the menu-bar app runs (it enforces session deadlines)
lid_close_actions.json  # what the lid-close actions changed: audio device UID + prior state, stopped pids with their identity triple
lid_close_audit.jsonl   # one line per lid-close apply/undo (never per tick)
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
- **Low battery wins over keep-awake, ownership still binds.** The guard
  releases the lid flag through the ownership-gated path. The only widening
  is the critical-battery emergency: RunClosed's own record from a previous
  boot counts as ownership there (audited). A flag set by another tool gets a
  loud notification, never a mutation.
- **Last-display guard.** Disabling the only active display is refused at the
  moment of the effect, not at render time.
- **One target per command.** A brightness command for display A never touches
  display B.
- **A session records its deadline before it touches the flag.** The session
  is journaled first; if the flag write then fails, the record is deleted. The
  expiry path releases through the ownership gate, and it may only release a
  record written by the boot the session started in — never an arbitrary stale
  one. A session that comes due while the machine slept still ends, because
  the continuous clock keeps counting through sleep (ADR 023).
- **A crash is not a way out of the deadline.** The app is not the only
  enforcer: a per-user LaunchAgent runs `runclosed-cli recover --backstop`
  every 60 s. It takes only PROTECTIVE actions — ends a session whose deadline
  passed and releases the lid flag at critical battery, then lets the Mac
  sleep. It never turns the flag ON and never performs the low-battery re-arm
  (that stays the app's job, so the debt is left on disk for it). It takes the
  cross-process lock non-blocking and reports "busy" (exit 75) instead of
  queueing behind the app or a CLI. When the app holds `app.lock` the backstop
  exits at once, but correctness never depends on that probe: every step is
  idempotent and read-back confirmed. The agent is registered through
  `SMAppService.agent(plistName:)`, so it dies with the bundle; approval
  happens in System Settings → Login Items, and the popup says so with a
  one-click link while it is pending. Being approved is not enough for the CLI
  to rely on it: every run writes `backstop_heartbeat.json`, and a timed
  session only starts (or extends) with the app closed when that record proves
  a successful run on this boot within the last 3 minutes (ADR 024).

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
                         #      lid-stay-awake, restore, login-item, helper,
                         #      low-battery (status / simulate, read-only),
                         #      session (start / extend / end / status),
                         #      recover --backstop (what the LaunchAgent runs),
                         #      backstop (status / register / login-items / unregister)
                         #      lid-close status (read-only) / simulate (pure decision)
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
- The recovery backstop protects a logged-in user's session only. **Nothing
  protects the Mac while no user is logged in** (at the login window, or before
  the first login after a restart): the LaunchAgent runs in the user's session,
  so it does not exist there. Turn the lid switch off before logging out.
- The backstop's registration, the approval gesture in System Settings and the
  real 60 s cadence have not been measured on hardware yet (unit-tested only).

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Benjamin Belaga.
