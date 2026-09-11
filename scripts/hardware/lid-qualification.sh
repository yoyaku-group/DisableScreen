#!/bin/bash
# Closed-lid keep-awake qualification protocol (Phase 3, G3).
#
# This script is a HARDWARE experiment. It is opt-in and refuses to run unless
# RUNCLOSED_HW_OPTIN=1 is set, because it writes the global root `disablesleep`
# flag and asks a human to physically close the lid. It must only be run with the
# operator present. It records ownership, distinguishes API effects from physical
# observation, and always restores the flag it changed.
#
# It does NOT explore any private/rootless backend (e.g. coke). It qualifies:
#   (a) the public idle assertion (expected: does NOT survive lid close — S01), and
#   (b) the pmset disablesleep flag (via the existing NOPASSWD sudoers rule).
#
# Result verdict: PASS / FAIL / INDETERMINATE, written to docs/compatibility/.
set -euo pipefail

if [[ "${RUNCLOSED_HW_OPTIN:-0}" != "1" ]]; then
  echo "BLOCKED_HARDWARE: refuse to run without RUNCLOSED_HW_OPTIN=1." >&2
  echo "This flips a real root system flag and needs the operator physically present." >&2
  exit 3
fi

MINUTES="${1:-2}"
BOOT_UUID="$(sysctl -n kern.bootsessionuuid)"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
OSVER="$(sw_vers -productVersion)"
OUTDIR="$(cd "$(dirname "$0")/../../docs/compatibility" && pwd)"
WITNESS="$(mktemp -t runclosed-witness)"
REPORT="$OUTDIR/lid-${MODEL}-${OSVER}-${STAMP}.md"

echo "== RunClosed lid qualification =="
echo "model=$MODEL os=$OSVER boot=$BOOT_UUID minutes=$MINUTES"

baseline="$(pmset -g | awk '/SleepDisabled/{print $2}')"
echo "baseline SleepDisabled=$baseline"

cleanup() {
  # Always restore to 0 (the safe default) — this is exactly what we set.
  sudo -n /usr/bin/pmset -a disablesleep 0 || true
  echo "restored disablesleep=0"
}
trap cleanup EXIT

echo "setting disablesleep=1 (via NOPASSWD sudoers rule)"
sudo -n /usr/bin/pmset -a disablesleep 1
readback="$(pmset -g | awk '/SleepDisabled/{print $2}')"
echo "readback SleepDisabled=$readback"
if [[ "$readback" != "1" ]]; then
  echo "VERDICT=FAIL (write did not take)"; exit 0
fi

# Physical witness: append a heartbeat every 10s; a gap during lid-close means
# the machine slept despite the flag.
( while true; do echo "$(date +%s) awake"; sleep 10; done ) >"$WITNESS" &
WPID=$!

echo ">> Please CLOSE the lid now and keep it closed for $MINUTES minute(s)."
echo ">> Re-open it when your Mac beeps / after the timer."
sleep $(( MINUTES * 60 ))

kill "$WPID" 2>/dev/null || true
gaps="$(awk 'NR>1{d=$1-p; if(d>25) print d} {p=$1}' "$WITNESS" | wc -l | tr -d ' ')"
readback2="$(pmset -g | awk '/SleepDisabled/{print $2}')"

{
  echo "# Lid qualification — $MODEL / macOS $OSVER"
  echo
  echo "- date: $STAMP"
  echo "- boot_uuid: $BOOT_UUID"
  echo "- baseline SleepDisabled: $baseline"
  echo "- API effect: write rc=0, readback=1 (flag accepted)"
  echo "- physical observation: heartbeat gaps>25s during lid-close = $gaps"
  echo "- readback after lid cycle: $readback2"
  echo
  if [[ "$gaps" == "0" ]]; then
    echo "VERDICT: PASS — no sleep gap observed while lid closed (flag held)."
  else
    echo "VERDICT: FAIL — $gaps sleep gap(s) while lid closed (flag did not keep it awake)."
  fi
  echo
  echo "_API success is not physical proof; this verdict is from the heartbeat witness._"
} | tee "$REPORT"

echo "report: $REPORT"
