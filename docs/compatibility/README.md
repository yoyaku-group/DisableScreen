# Compatibility matrix

Honest by construction: a row only appears once it has been **tested** on the
named machine. Compiling alone earns no "supported" badge.

| Machine | macOS | idle assertion | closed-lid keep-awake | external display |
|---|---|---|---|---|
| Apple M5 Max | 26.6 | PASS (`IOPMAssertionCreateWithName`, verified via `pmset -g assertions`) | **PASS** (2026-09-20: toggled from the popup, lid physically closed, machine stayed awake — `pmset -g` read-back `SleepDisabled 1` + ownership record, restored to `0` after) | NOT TESTED (only one built-in XDR panel available on this machine) |

Notes:

- `idle assertion` covers preventing **idle** sleep only. Apple's public
  assertion API (`kIOPMAssertionTypePreventUserIdleSystemSleep`) does **not**
  cover lid close — that is what the `pmset disablesleep` path is for.
- The closed-lid path mutates a root-owned, persistent flag. The app records
  ownership `{boot, referenceState}` and restores only what it set; a flag
  owned by a previous boot is kept as `recoveryPending` and never silently
  flipped (see `DECISIONS.md` ADR 015).
