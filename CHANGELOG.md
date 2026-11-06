# Changelog

All notable changes to RunClosed are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
  at 7 days.
- `runclosed session start --for <2h|90m|1h30m> | start --indefinite | extend
  [30m] | end | status [--json]`. Mutating subcommands take the same lock as
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
