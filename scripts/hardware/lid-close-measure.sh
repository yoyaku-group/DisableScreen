#!/bin/bash
# Lid-close action qualification, part 1 — MEASURE FIRST (ADR 026).
#
# HARDWARE experiment, opt-in, operator present. Refuses to run unless
# RUNCLOSED_HW_OPTIN=1.
#
# This script answers the ONE question the lot deliberately did not answer in
# code: **with the lid closed, does the built-in panel stay ACTIVE?** The
# reviewing pass contested Insomnia's claim that the panel is already off when
# the lid shuts, and `DisplayBrightness.set` answers OK even when nothing
# happens — so the undo of a brightness or keyboard-backlight action could not
# be verified. Until this script measures the panel, those two actions stay
# out of the product and marked NOT_TESTED.
#
# It is a READ-ONLY witness: it never writes `pmset`, never toggles the flag,
# never signals a process and never mutates an audio device. It only samples.
#
# Protocol (~5 min):
#   1. Have a keep-awake session running (the app's popup, or the CLI).
#      Run the script with the lid OPEN, then close the lid.
#   2. Ctrl-C ends the run and writes the verdict.
#   3. The samples carry the clamshell bit, the built-in panel state, and the
#      CLI's own read-only view of the three conditions.
#
# Verdict written to docs/compatibility/: MEASURED with what the built-in panel
# did while the lid was closed, or INCONCLUSIVE when the run never saw the lid
# closed.
set -euo pipefail

if [[ "${RUNCLOSED_HW_OPTIN:-0}" != "1" ]]; then
  echo "BLOCKED_HARDWARE: refuse to run without RUNCLOSED_HW_OPTIN=1." >&2
  echo "This observes the display while you close the lid; the operator must be present." >&2
  exit 3
fi

CLI="${RUNCLOSED_CLI:-/Applications/RunClosed.app/Contents/MacOS/runclosed-cli}"
INTERVAL="${INTERVAL:-5}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
OSVER="$(sw_vers -productVersion)"
OUTDIR="$(cd "$(dirname "$0")/../../docs/compatibility" && pwd)"
REPORT="$OUTDIR/lid-close-measure-${MODEL}-${OSVER}-${STAMP}.md"
LOG="$(mktemp -t runclosed-lidmeasure)"

[[ -x "$CLI" ]] || { echo "missing CLI: $CLI" >&2; exit 1; }
# Exit 3 means "the command ran and something is owed" — the command EXISTS.
# Only anything else means an old build without `lid-close`.
rc=0; "$CLI" lid-close status >/dev/null 2>&1 || rc=$?
if [[ "$rc" != "0" && "$rc" != "3" ]]; then
  echo "CLI has no usable lid-close command (exit $rc; old build?)" >&2
  exit 1
fi

# The clamshell bit, straight from IOKit (the same property the product reads).
lid() { ioreg -r -k AppleClamshellState -d 4 2>/dev/null | awk '/AppleClamshellState/{print $NF; exit}'; }

# The three conditions as the PRODUCT reports them, so the witness cannot
# disagree with the thing it is qualifying.
conditions() {
  # `lid-close status` exits 3 when a recovery obligation is outstanding — a
  # VALID outcome with valid JSON, not a failure of this probe. Under
  # `set -o pipefail` that 3 would propagate out of this function and `set -e`
  # would abort the whole measurement before the report is written (gate
  # finding, `Le code de statut 3 interrompt la mesure sans rapport`). The
  # status is deliberately discarded here: this witness reads the readings, and
  # the exit code carries a different question.
  { "$CLI" lid-close status --json 2>/dev/null || true; } | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception:
    print("conditions=unreadable"); raise SystemExit
c=d.get("conditions",{}); s=d.get("settings",{})
print("lidClosed=%s external=%s sessionActive=%s enabled=%s" % (
  c.get("lidClosed"), c.get("externalDisplayConnected"),
  c.get("sessionActive"), s.get("enabled")))'
}

# Built-in panel state, read-only. `CGDisplayIsActive` needs CoreGraphics; when
# pyobjc is absent the sample says so instead of guessing.
panel() {
  python3 - <<'PY' 2>/dev/null || echo "builtin=unavailable"
try:
    import Quartz
except Exception:
    print("builtin=unavailable(no pyobjc)")
    raise SystemExit
# pyobjc answers `(err, (ids,), count)`; anything else is reported, never
# guessed — this witness exists to remove doubt, not to add some.
result = Quartz.CGGetActiveDisplayList(16, None, None)
# The FIRST element is a CGError. A non-zero one means the enumeration FAILED,
# and an empty list from a failed query says nothing about the panel — reading
# it as "not in the active list" would turn a broken observation into a
# definitive "the panel was off" verdict (gate finding).
if len(result) != 3 or not isinstance(result[1], tuple):
    print("builtin=unavailable(unexpected CGGetActiveDisplayList shape)")
    raise SystemExit
if result[0] != 0:
    print("builtin=unavailable(CGGetActiveDisplayList error %s)" % (result[0],))
    raise SystemExit
ids = list(result[1])
for d in ids:
    if Quartz.CGDisplayIsBuiltin(d):
        print("builtin=ACTIVE asleep=%s online=%s" % (
            bool(Quartz.CGDisplayIsAsleep(d)), bool(Quartz.CGDisplayIsOnline(d))))
        break
else:
    print("builtin=NOT_IN_ACTIVE_LIST")
PY
}

echo "== RunClosed lid-close measurement (ADR 026, measure first) =="
echo "model=$MODEL os=$OSVER log=$LOG"
echo "Run it with the lid OPEN, then close the lid. Ctrl-C to finish."
echo

saw_lid_closed=0
saw_panel_active=0
saw_panel_inactive=0
saw_panel_unreadable=0
# Ctrl-C must WRITE THE REPORT, not die wherever the interrupt lands. A flag set
# by the trap is checked before each sample and before each sleep, so an
# interrupt that arrives while a probe is running still ends the run cleanly
# (gate finding, `Ctrl-C only ends measurement when it interrupts sleep`).
interrupted=0
trap 'interrupted=1; echo "interrupted"' INT
while [[ "$interrupted" == "0" ]]; do
  # A probe interrupted by Ctrl-C exits 130, which `set -e` would turn into a
  # silent abort BEFORE the report is written. Each assignment tolerates that,
  # so the trap's flag is what ends the run (gate finding, `Ctrl-C during a
  # probe can bypass report generation`).
  # Read the lid BEFORE and AFTER the panel probe: agreement between the two
  # endpoints does not prove the state DURING it, and a lid that closed for the
  # first read, opened while panel() ran and closed again before the last one
  # would otherwise qualify an open-lid panel reading (gate finding, `Sequential
  # probes still allow an open-lid panel reading to qualify`).
  l="$(lid || true)"; p="$(panel || true)"; l2="$(lid || true)"; c="$(conditions || true)"
  line="$(date '+%F %T') clamshell=$l $p $c"
  echo "$line" | tee -a "$LOG"
  # A sample only qualifies if the machine is in the configuration the feature
  # targets: an ACTIVE keep-awake session and NO external display. Without that
  # gate a run with no session measures ordinary lid-close sleep, which proves
  # nothing about the conditions the verdict talks about (gate finding,
  # `Qualification ignores session and external-display conditions`).
  # ALL FOUR must agree: the sample's own clamshell read, the PRODUCT's
  # lidClosed reading, an active session and no external display. Checking only
  # session/external qualified samples that SPANNED a lid transition — the
  # operator opens the lid between the two probes, `panel()` then reports the
  # now-active built-in display, and the run produced a definitive
  # closed-lid-ACTIVE verdict from an open-lid sample (gate finding,
  # `Sequential probes can qualify an open-lid panel reading`).
  if [[ "$l" == "1" || "$l" == "Yes" || "$l" == "yes" ]] \
     && [[ "$l2" == "1" || "$l2" == "Yes" || "$l2" == "yes" ]] \
     && [[ "$c" == *"lidClosed=True"* ]] \
     && [[ "$c" == *"sessionActive=True"* ]] \
     && [[ "$c" == *"external=False"* ]]; then
    saw_lid_closed=1
    # Match the EXACT tokens `panel()` emits. A substring test for "ACTIVE"
    # also matches "NOT_IN_ACTIVE_LIST", which reported an absent panel as
    # ACTIVE and inverted the verdict (caught by ai-review-gate).
    case "$p" in
      "builtin=ACTIVE "*) saw_panel_active=1 ;;
      "builtin=NOT_IN_ACTIVE_LIST") saw_panel_inactive=1 ;;
      *) saw_panel_unreadable=1 ;;
    esac
  fi
  sleep "$INTERVAL" || break
done

# A verdict needs EVIDENCE. Silence about the panel is not proof that it was
# off, so a run whose every closed-lid sample was unreadable is INCONCLUSIVE
# rather than a definitive "no action warranted" (caught by ai-review-gate).
if (( ! saw_lid_closed )); then
  verdict="INCONCLUSIVE — no usable sample: the run needs the lid Closed AND an active keep-awake session AND no external display. Without all three nothing about this feature was measured"
elif (( saw_panel_active )); then
  verdict="MEASURED — the built-in panel stayed ACTIVE with the lid closed. Brightness and keyboard backlight remain CANDIDATES, and a readback criterion is still required before any code is written"
elif (( saw_panel_inactive )); then
  verdict="MEASURED — the built-in panel was not active with the lid closed. No brightness or keyboard-backlight action is warranted, and ADR 026's NOT_TESTED stands as the decision"
else
  verdict="INCONCLUSIVE — the lid was seen closed but no usable panel reading was obtained (pyobjc missing or an unexpected display-list shape); install pyobjc or fix the probe and re-run"
fi
{
  echo "# Lid-close measurement — $MODEL macOS $OSVER ($STAMP)"
  echo
  echo "Verdict: $verdict"
  echo
  echo "Read-only witness: no \`pmset\` write, no flag toggle, no signal, no audio mutation."
  echo
  echo '```'
  cat "$LOG"
  echo '```'
} >"$REPORT"
echo "VERDICT=$verdict → $REPORT"
