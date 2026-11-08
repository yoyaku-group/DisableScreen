# Changelog

All notable changes to RunClosed are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Lid-close actions (ADR 026). During a keep-awake session, when the lid is
  closed and no external display is attached, RunClosed mutes the default
  audio output and (on its own, separate switch) pauses Slack, Discord and
  WhatsApp. The governing principle is that **nothing is touched without a
  proven way back**: every effect is journaled BEFORE it is applied, the undo
  is verified by readback, and a journal entry is cleared only once the prior
  state is proven restored. `LidCloseActionPolicy` (Core) is pure and takes
  three conditions together — a session in progress (an indefinite session
  counts; a paused one does not), the lid closed per `ClamshellObserver`, and
  **no external display attached**, with `unknown` counting as attached. All
  three are named refusals, so a post-mortem reads the cause instead of
  "nothing happened". A docked Mac with the lid closed is therefore never
  touched — the rule that protects the operator's desk setup. The whole feature
  is OFF by default and is switched on from the menu bar's right-click menu,
  where the app-pause list is visible and the app-pause switch is separate:
  freezing a process is far more intrusive than muting a device. The sound path
  records the device by **UID** (the `AudioObjectID` is a per-process handle
  that changes across restarts, so a journal holding only the id could not find
  the device it muted) together with its prior mute flag and volume, then reads
  back: a device that was already silent is left alone and journaled as
  nothing, so the undo never turns sound back on that the operator had turned
  off, and a device that has disappeared is noted, never an error. The app
  path stops a process with `SIGSTOP` after journaling its **identity triple**
  (pid, process start seconds + microseconds, boot session) — a pid alone is
  recycled by the kernel, so "pid 4711 is stopped" is not a fact that survives
  a few minutes — and confirms the stopped state with `proc_pidinfo`
  (`PROC_PIDTBSDINFO`), because `kill(2)` returning 0 means "delivered", not
  "stopped". `SIGCONT` requires the identity to be re-proved: a process whose
  pid now belongs to something else, or that has vanished, is left stopped and
  reported as **"to verify"**, never resumed blindly — resuming the wrong
  process is strictly worse than leaving an app paused. An app we did not stop
  ourselves is never resumed, because the journal is the only authority. The
  undo runs in the reverse order everywhere (apps then sound) and at four
  points the plan names: the lid reopening or any condition stopping, the end
  of a session, a quit, and — the one this lot adds deliberately — the ADR 024
  backstop, which runs the SAME policy rather than a copy so a Mac whose app
  crashed does not stay muted with an app frozen. The undo also runs
  immediately BEFORE a thermal or low-battery release sleeps the Mac: a machine
  that goes down muted with a frozen app comes back in that state, and nobody
  would connect it to the heat event. A pending journal is itself a reason for
  the backstop to take the lock, even with no session and no ownership record,
  which is exactly the crashed-app case. Screen brightness and keyboard
  backlight are **NOT** part of this lot: `DisplayBrightness.set` answers OK
  without an effect, so the undo would not be verifiable — the measurement is
  deferred to the hardware qualification and the fields are marked NOT_TESTED.
  Read-only CLI `runclosed lid-close status [--json]` (settings, the three
  readings, the decision, the journal and the "to verify" list; exit 3 when
  something is left to verify) and `runclosed lid-close simulate` (a pure
  decision on injected values, mutating nothing). The app's quit teardown
  undoes inside the same `LidWriteLock` section as the rest of the release.

- Thermal guard and clamshell detection (ADR 025). `pmset disablesleep 1`
  also blocks macOS's own emergency sleep, and nothing covered HEAT: a Mac
  sitting with the lid closed under a fleet of agents can run hot with nothing
  cooling it, because the panel is off, the workload continues, and macOS
  cannot sleep the machine to cool it. That is the second half of the
  2026-10-14 incident. One rule is added: when the machine is hot and nothing
  is cooling it, release the flag and let it sleep. `ThermalPolicy` (Core) is
  pure — `(Input, Latch) -> (Decision, Latch)`, like `LowBatteryPolicy` — and
  has **no enable case at all**: a `critical` state with the lid closed, no
  display attached and the flag provably ours releases and sleeps immediately;
  `serious` in that same situation gives a ten-minute grace period so a
  compiler burst does not end a session, then releases. The clock measures ten
  minutes of heat that COULD be released: any interruption (the lid reopened,
  a display attached, ownership lost, the flag going off) resets it, so a Mac that ran hot and then
  cooled does not release the instant the lid comes back down. Three refusals make it
  safe: an open lid (the air circulates and the operator is there), an attached
  display (the machine is in use), and a flag that is not ours (B2 — alert
  only, never mutated; a record from a previous boot is not active ownership
  either). Unknown is never `false`: an unreadable clamshell bit or display
  inventory refuses the release, so the doubt never releases. Heat **ends** the
  session (clearing the pending battery re-arm) rather than pausing it: a
  machine that overheated must not be woken again by the guard. `ThermalReadback`
  maps `ProcessInfo.processInfo.thermalState`; a `thermalStateDidChangeNotification`
  observer ticks immediately so a `critical` does not wait for the 30 s timer.
  `ClamshellObserver` (new — the repository had no clamshell detection) reads
  `AppleClamshellState` on `IOPMrootDomain`, collapses the close burst into one
  tick with a 2 s debounce, and is backed by a re-read on the existing 5 s
  refresh because a notification can be missed across a sleep. The thermal step
  runs FIRST in the app's single `LidWriteLock` section, before the battery
  step — heat kills faster than the drain — and a heat tick stops there, so the
  battery re-arm branch can never turn the flag back on for a machine that is
  still hot. The ADR 024 backstop runs the SAME policy: a session with no end
  time must be protected from heat even if the app crashed. `ThermalGuardSettings`
  is a separate kill switch (`defaults write com.benjaminbelaga.RunClosed
  thermalGuardEnabled -bool false`, absent = enabled), honoured by the app and
  by the backstop, and independent of the battery one in both directions. The
  audit mechanics are extracted into `JSONLAuditLog` (same `O_APPEND` discipline,
  `low_battery_audit.jsonl` byte-for-byte unchanged) and `thermal_audit.jsonl`
  gets one line per ACTION, never one per minute without effect. The CLI gains
  read-only `thermal status [--json]` and pure `thermal simulate <state>` with
  `--lid`, `--external-display`, `--lid-flag`, `--ownership` and `--since`; the
  popup says "Session ended — heat" and the menu bar `ended: heat`. 118 new tests (policy grid, grace hold,
  service on fakes, backstop, shared tick, persistence, simulate), 575/575.

- Recovery backstop (ADR 024). Until now only the running app enforced a
  session deadline and the low-battery guard, so a crash or a quit left
  `pmset disablesleep 1` on with nothing to turn it off: the Mac stayed awake
  with the lid closed until the battery died (the 2026-10-14 incident behind
  ADR 022). A per-user LaunchAgent now runs `runclosed-cli recover --backstop`
  every 60 s. It takes only PROTECTIVE actions while the app is not running —
  it ends a session whose deadline passed (releasing through the ownership
  gate, `.sessionRecovery` for the session's own previous-boot record) and, at
  critical battery, releases the flag and lets the Mac sleep. It never turns
  the flag ON and never performs the low-battery re-arm: that debt is left on
  disk for the app, so the agent cannot wake the Mac unattended. It takes the
  cross-process lock non-blocking and exits 75 when another writer holds it,
  the conventional "retry next minute"; when the app holds `app.lock` it exits
  at once. A minute with nothing to protect costs no `pmset` call and no lock,
  and `recovery_audit.jsonl` gets a line only when a step acted or failed.
  Registered with `SMAppService.agent(plistName:)` — never `launchctl
  bootstrap`, which would leave a job outliving a deleted bundle — and
  registered at every launch when it is not registered yet. A pending approval
  shows "Recovery backstop off — approve it in System Settings" in the popup
  with a Login Items link. `status` and `doctor` gain a `backstop` block, and
  the CLI gains `recover --backstop` and `backstop status|register|login-items|
  unregister`. `session start --for` and `session extend` are now allowed while
  the app is closed, provided the agent reports `enabled`; a merely pending
  approval enforces nothing and keeps the refusal, whose message names both
  ways out. Being registered is also not enough: every run writes
  `backstop_heartbeat.json`, and the CLI only treats the agent as an enforcer
  when that record proves a successful run on this boot within the last 3
  minutes — an approved agent whose program never actually runs (a
  `BundleProgram` that does not resolve) therefore keeps the refusal instead of
  letting a deadline go unenforced. A run that failed, a heartbeat from before
  a restart, or a stale one after a wake all refuse; `backstop status`,
  `status` and `doctor` report `lastRunAt`, `lastExitCode`, `recentRun` and
  `enforcing`. The popup applies the same rule, so it no longer says nothing
  about an approved-but-never-running agent. A busy minute (another writer held
  the lock) no longer counts as proof the agent could act, and unregistering is
  remembered as an explicit operator decision so the next app launch does not
  silently register the agent again — that decision is now SHOWN (`backstop
  status`, the popup and the refusal message name it) instead of reading as
  "never registered", which pointed the operator at a System Settings screen
  where nothing would ever appear. An agent minute pre-empted by another writer
  (exit 75) is reported as busy rather than as a failed run. The agent's
  diagnostics go to `~/Library/Logs/RunClosed/`, never `/tmp`: that directory is
  world-writable, so a fixed name there let another local account pre-create it
  as a symlink and have launchd write to a file of its choosing with your
  privileges. Known limit, stated in the README: nothing
  protects the Mac while no user is logged in.

### Fixed

- Recovery backstop: a failing protective release slept the Mac once per
  minute. `protectiveStep()` restores the app's notification latches on purpose
  (the backstop shows no notification, so consuming them would silence a
  warning nobody saw), but the sleep-once memory shared one of those fields —
  restoring it erased the memory every run, so a stale sudoers rule put the Mac
  to sleep every 60 s forever, including right after the operator woke it.
  Sleep suppression and notification suppression are now separate states:
  `protectiveSleepTried` belongs to the backstop, `failedReleaseSleepTried`
  stays the app's and is no longer touched. The episode ends when the charge
  rises above the warn band, so a later discharge may sleep again.
- Recovery backstop: a failure episode was never forgotten, so a later failure
  with the same reason got no audit line at all. A healthy run wrote `nil`,
  which the heartbeat read as "keep the previous key" — the same sentinel used
  for "the battery step did not run". `batteryStepRan` tells the two apart: a
  healthy battery step clears the key, only a minute that never evaluated the
  battery carries it forward.
- Recovery backstop: `session start --for` and `session extend` could accept a
  deadline nothing would enforce. The backstop probe is read before
  `LidWriteLock` (it is an XPC round-trip; holding the lock across a slow `smd`
  stalls the app's tick), so an operator `backstop unregister` completing while
  the command waited for the lock left the pre-lock answer `true`.
  `backstopStillEnforcingLocked()` re-checks the two facts an unregister
  actually changes — the recorded opt-out and the heartbeat freshness — inside
  the section, with no XPC. A revocation made in System Settings during that
  same window is still not covered: it is asynchronous, leaves no local trace,
  and closing it would mean putting the XPC back under the lock.
- ADR 023 follow-ups. Turning the lid switch on now records an indefinite
  session only when the read-back verified the flag ON: a write that reported
  success without confirming it used to leave a deadline-less "running
  session" on every surface for a flag nobody observed on, so it now behaves as
  a failure for the session record. `runclosed session status --json` names the
  day when the deadline is not today ("Until Tue 14:30"), as the popup already
  did — a 7-day session read as "Until 14:30" claims today. The
  `SessionService.end(byOperator:)` documentation now matches the code: an
  indefinite End is an operator command only when `byOperator` is true.

### Added

- Timed keep-awake sessions (ADR 023). The lid stay-awake switch used to have
  no end time: forgetting it left the Mac awake until the low-battery guard
  stepped in at 10 %. The lid row now offers 1 h / 2 h / 4 h / 8 h buttons and
  shows "Until 14:30 · 2 h 41 left" while a session runs, with "+30 min" and
  "End"; the remaining time also appears next to the menu-bar icon. The switch
  itself is unchanged — turning it on creates an indefinite session, so
  existing behaviour is preserved. Deadlines are tracked on
  `mach_continuous_time`, which keeps counting while the machine sleeps (the
  uptime clock does not), with the wall clock as the cross-reboot fallback. A
  timed session refuses to start on a flag RunClosed does not own, because its
  expiry would silently fail the ownership check. A low-battery release pauses
  the session instead of ending it, and the guard only re-arms the flag while
  the session is still valid. Expiry runs inside the existing guard tick, in
  the same cross-process lock section, and a wake notification triggers a tick
  so an overnight deadline is honoured on wake. Quitting ends the session
  through the same path as End and expiry, so a re-arm owed to a paused
  session cannot flip the flag back on at the next launch. A session is capped
  at 7 days. A battery-paused session shows "Paused (low battery)" and stays
  paused when extended; only the guard's re-arm turns the flag back on. The
  plain switch keeps its ADR 022 re-arm after a reboot and across a quit.
  Turning the switch on over a live timed session (for example one paused by
  the battery guard) resumes it with its deadline instead of replacing it.
  A pause reason written by a later version keeps the session paused. The
  pause also ends when the flag is back on and ours by any path. End in the popup
  on an indefinite session is the switch OFF and turns off an adopted flag;
  `session end` keeps the ownership check like `lid-stay-awake off`, and only
  `session end --operator` turns off a flag another tool set. End on a timed
  session never turns off a flag another tool owns. When a deadline
  or End finds the flag still on but not RunClosed's (for example a lost
  ownership record), the session ends with a "Session ended — Mac still
  awake" alert instead of a plain "Session ended", and `session end` exits 3.
  While the app
  runs it holds `app.lock`; until the launchd backstop ships, the CLI refuses
  a timed session when the app is not running, since nothing would end it.
  The check runs under the lid lock, and the app retries `app.lock` on every
  tick if it could not take it at launch. A running session whose flag reads
  off (a crash between the record and the flag, `lid-stay-awake off`, or
  `pmset` by hand) is cleared on the next tick instead of counting down for
  nothing. Switching the low-battery guard off no longer stops session
  deadlines: the app then runs the session step on its own. A paused session
  whose re-arm was cancelled is cleared too. A start whose `pmset` write
  failed its readback checks the flag again and turns it back off if the
  write landed anyway. Quitting gives `app.lock` up inside the lid lock, so a
  CLI start queued behind the quit is refused. `session extend` is refused
  the same way when the app is not running. A quit whose flag release fails
  keeps the session, logs it and, for a timed session, warns "RunClosed quit
  — Mac still awake" before exiting. The menu bar no longer reads
  `session.json` on the main thread. A duration whose units repeat or do not
  get smaller (`2h3h`, `30m2h`) is a usage error instead of a sum.
- `runclosed session start --for <2h|90m|1h30m> | start --indefinite | extend
  [30m] | end | status [--json]`. `--for` together with `--indefinite` is a
  usage error; a timed start or an extend without the menu-bar app running exits 3. Mutating subcommands take the same lock as
  `lid-stay-awake on|off`; exit codes stay 0 / 3 (refused by policy) / 5
  (backend failure) / 64 (usage). The session record lives in
  `~/Library/Application Support/RunClosed/session.json`, so a future launchd
  recovery backstop can read it.
- Low-battery guard (ADR 022). The lid stay-awake flag (`pmset
  disablesleep 1`) also blocks macOS's emergency sleep, so a Mac left on
  battery with a heavy workload could drain to 0 % and power off hard. On
  battery, RunClosed now warns at 20 %. At 10 % (or ≤ 10 minutes left once
  below 20 %) it turns the flag off and runs `pmset sleepnow`. With
  `hibernatemode 3` the machine hibernates instead of dying, and every
  process survives. The flag comes back on automatically once on AC and above
  15 %. The guard never acts on AC. A flag RunClosed itself set on a previous
  boot (the flag survives restarts) is released as an emergency at the
  critical threshold, with an audit line in `low_battery_audit.jsonl`; a flag
  set by another tool is never touched, only a critical notification. Kill switch:
  `defaults write com.benjaminbelaga.RunClosed lowBatteryGuardEnabled -bool false`.
  Guard ticks, the popup switch and `runclosed lid-stay-awake on|off` are
  serialised by a cross-process file lock, so an operator command always wins
  over an automatic re-arm. When the flag was not set by RunClosed on the
  current boot, the 20 % notice says explicitly that the Mac is NOT
  protected instead of promising a sleep. The re-arm also waits while the
  battery still discharges on AC (adapter too weak for the load).
- `runclosed low-battery status` (live battery readback + guard decision,
  ownership record / `recoveryPending`, protection level and one-click remedy;
  read-only) and `runclosed low-battery simulate <onBattery> <percent>
  <minutes>` (pure dry-run decision, never mutates).
- `scripts/hardware/low-battery-qualification.sh`: opt-in, read-only witness
  for the hardware qualification run with the operator present.

### Fixed

- The "Keep awake with lid closed" switch could get stuck ON after a reboot:
  `disablesleep` survives a restart, the ownership record then belonged to
  the previous boot, and every click to turn it off was refused silently.
  The popup switch is now treated as an explicit operator command and always
  applies (the automatic restore-on-quit still only touches a flag the app
  set on the current boot). A refused toggle now shows a message under the
  label instead of snapping back silently. The CLI gains
  `runclosed lid-stay-awake off --operator` for the same case (ADR 021).
- `runclosed doctor` no longer reports the lid backend as "unqualified": it
  now states the two facts separately — the app toggle path is qualified live
  (`docs/compatibility/README.md`) and mutates through
  `sudo -n /usr/bin/pmset`, while the CLI `run --lid` wrapper is a separate,
  unimplemented feature (ADR 007). The `run --lid` refusal message says the
  same instead of blaming the hardware.

## [0.2.0] - 2026-09-20

### Added

- Menu-bar popup with real toggles: per-display on/off switches, brightness
  sliders, resolution pickers, a lid stay-awake switch, and an Open-at-login
  switch — replacing the read-only menu of the G2a tranche.
- Native brightness control for the built-in display (CoreDisplay) and a
  software-dim overlay for external displays.
- `runclosed login-item status|on|off` CLI subcommand.
- English is now the base language; French ships as a localization
  (`fr.lproj`). Unshipped languages fall back to English.

### Fixed

- `pmset -g` parsing: the read-back split on literal spaces but `pmset`
  separates columns with tabs, so the lid state always read as OFF and every
  toggle was reported as failed while the flag had actually changed. Now
  whitespace-run parsing, plus a bounded retry for the kernel flag's
  propagation lag.
- Brightness: the CoreDisplay framework handles now load from
  `/System/Library/Frameworks/` (the PrivateFrameworks path returns nil under
  a direct `dlopen`).
- The display switch is greyed out for the last active display instead of
  offering a toggle that would be refused.

### Changed

- The Python `DisableScreen` app is retired as the daily driver (kept in-tree
  as the audited baseline). The Swift app is the product.
- Builds are signed with the hardened runtime (`--options runtime
  --timestamp`) and the 0.2.0 bundle is notarized and stapled, so the released
  app launches under Gatekeeper without a warning.
