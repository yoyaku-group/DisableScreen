#!/bin/bash
# Low-battery guard qualification protocol (ADR 022).
#
# HARDWARE experiment, opt-in, operator present. Refuses to run unless
# RUNCLOSED_HW_OPTIN=1. This script is a READ-ONLY witness: it never writes
# `pmset` and never calls `sleepnow` itself. The installed menu-bar app (the
# build that ships the guard) performs the release + sleep; this script records
# the evidence around it and writes a verdict to docs/compatibility/.
#
# Protocol (≈ 1 h on a heavy workload, longer when idle):
#   1. Install the guard build. In the popup, switch "Keep awake with lid
#      closed" OFF then ON so the flag is owned on THIS boot:
#        runclosed-cli lid-stay-awake status   → "ownedByThisBoot": true
#   2. Unplug the charger at ≤ 25 %, then run:
#        RUNCLOSED_HW_OPTIN=1 scripts/hardware/low-battery-qualification.sh
#   3. Expected: a notification at 20 %; at 10 % (or ≤ 10 min left inside the
#      20 % band) SleepDisabled drops to 0 and the Mac goes to sleep
#      (hibernatemode 3 → RAM image on disk).
#   4. Wake the Mac, plug the charger. Above 15 % on AC the guard re-arms the
#      flag (SleepDisabled back to 1). Ctrl-C ends the run at any time.
#
# Verdict: PASS (release + sleep gap + re-arm observed) / INDETERMINATE.
set -euo pipefail

if [[ "${RUNCLOSED_HW_OPTIN:-0}" != "1" ]]; then
  echo "BLOCKED_HARDWARE: refuse to run without RUNCLOSED_HW_OPTIN=1." >&2
  echo "This drains the battery to 10 % on purpose and needs the operator present." >&2
  exit 3
fi

CLI="${RUNCLOSED_CLI:-/Applications/RunClosed.app/Contents/MacOS/runclosed-cli}"
INTERVAL="${INTERVAL:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
OSVER="$(sw_vers -productVersion)"
OUTDIR="$(cd "$(dirname "$0")/../../docs/compatibility" && pwd)"
REPORT="$OUTDIR/low-battery-${MODEL}-${OSVER}-${STAMP}.md"
LOG="$(mktemp -t runclosed-lowbat)"

[[ -x "$CLI" ]] || { echo "missing CLI: $CLI" >&2; exit 1; }
"$CLI" low-battery status >/dev/null || { echo "CLI has no low-battery command (old build?)" >&2; exit 1; }

flag() { pmset -g | awk '/SleepDisabled/{print $2}'; }
pct() { pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%'; }
src() { pmset -g batt | head -1 | sed -E "s/.*'(.*)'.*/\1/"; }
decision() { "$CLI" low-battery status | python3 -c 'import json,sys;d=json.load(sys.stdin)["decision"];print(d["action"]+"/"+d["reason"])'; }

echo "== RunClosed low-battery qualification =="
echo "model=$MODEL os=$OSVER hibernatemode=$(pmset -g | awk '/hibernatemode/{print $2}') log=$LOG"
echo "ownership: $("$CLI" lid-stay-awake status | tr -d '\n' | tr -s ' ')"

saw_release=0 saw_gap=0 saw_rearm=0
prev_flag="$(flag)" prev_ts="$(date +%s)"
trap 'echo "interrupted"' INT
while true; do
  now="$(date +%s)"; f="$(flag)"; p="$(pct)"; s="$(src)"; d="$(decision)"
  line="$(date '+%F %T') src=$s pct=$p SleepDisabled=$f decision=$d"
  echo "$line" | tee -a "$LOG"
  # A wall-clock gap much larger than the interval = the Mac slept.
  if (( now - prev_ts > INTERVAL * 3 )); then
    saw_gap=1
    echo "  gap of $(( now - prev_ts ))s → slept; pmset log:" | tee -a "$LOG"
    pmset -g log | grep -E " (Sleep|Wake|Hibernate) " | tail -4 | tee -a "$LOG" || true
  fi
  [[ "$prev_flag" == "1" && "$f" == "0" && "$s" == "Battery Power" ]] && saw_release=1
  [[ "$prev_flag" == "0" && "$f" == "1" && "$s" == "AC Power" ]] && saw_rearm=1
  (( saw_release && saw_gap && saw_rearm )) && break
  prev_flag="$f" prev_ts="$now"
  sleep "$INTERVAL" || break
done

verdict=INDETERMINATE
(( saw_release && saw_gap && saw_rearm )) && verdict=PASS
{
  echo "# Low-battery guard qualification — $MODEL macOS $OSVER ($STAMP)"
  echo
  echo "Verdict: **$verdict** (release=$saw_release sleep-gap=$saw_gap rearm=$saw_rearm)"
  echo
  echo '```'
  cat "$LOG"
  echo '```'
} >"$REPORT"
echo "VERDICT=$verdict → $REPORT"
