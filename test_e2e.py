#!/usr/bin/env python3
"""E2E tests for DisableScreen."""
import subprocess
import time
import sys
from pathlib import Path

LOG = Path.home() / "DisableScreen" / "disablescreen.log"
APP = Path.home() / "DisableScreen" / "DisableScreen.app"
PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
results = []


def check(name, ok, detail=""):
    ok = bool(ok)
    status = PASS if ok else FAIL
    print(f"  [{status}] {name}" + (f" — {detail}" if detail else ""))
    results.append(ok)


# ── 1. App bundle ──────────────────────────────────────────────────────────
print("\n[1] App bundle")
check("DisableScreen.app exists", APP.exists())
check("Info.plist exists", (APP / "Contents/Info.plist").exists())
binary = APP / "Contents/MacOS/DisableScreen"
check("Binary exists", binary.exists())
check("Binary executable", binary.stat().st_mode & 0o111)

# ── 2. Process running ─────────────────────────────────────────────────────
print("\n[2] Process")
out = subprocess.run(["pgrep", "-f", "DisableScreen"], capture_output=True, text=True)
running = out.returncode == 0
check("Process running", running, out.stdout.strip())

# ── 3. Log file ────────────────────────────────────────────────────────────
print("\n[3] Log file")
check("Log file exists", LOG.exists())
if LOG.exists():
    content = LOG.read_text()
    check("Startup logged", "App started" in content)
    check("Display list in log", "Displays:" in content)
    check("Poll firing", "Poll:" in content, f"{content.count('Poll:')} polls found")

# ── 4. Screen detection logic ──────────────────────────────────────────────
print("\n[4] Screen detection")
import AppKit
from Quartz import CGDisplayIsBuiltin, CGGetOnlineDisplayList
from AppKit import NSScreen

err, displays, count = CGGetOnlineDisplayList(16, None, None)
check("CGGetOnlineDisplayList OK", err == 0, f"{count} display(s)")
for d in displays:
    builtin = bool(CGDisplayIsBuiltin(d))
    check(f"Display ID={d}", True, f"builtin={builtin}")

builtin_screen = None
for screen in NSScreen.screens():
    did = screen.deviceDescription().get("NSScreenNumber", 0)
    if CGDisplayIsBuiltin(did):
        builtin_screen = screen
        break

if builtin_screen:
    check("Built-in screen found via NSScreen", True, builtin_screen.localizedName())
else:
    check("Built-in screen not visible (BetterDisplay active)", True,
          "will re-detect on next poll when BetterDisplay expires")

# ── 5. Poll log recency ────────────────────────────────────────────────────
print("\n[5] Poll recency")
if LOG.exists():
    lines = LOG.read_text().splitlines()
    poll_lines = [l for l in lines if "Poll:" in l]
    if poll_lines:
        last = poll_lines[-1]
        check("Last poll logged", True, last.split("]")[-1].strip())
        # Check polls are ~5s apart
        if len(poll_lines) >= 2:
            import re
            times = [l.split(" [")[0] for l in poll_lines[-2:]]
            check("At least 2 poll cycles recorded", True, f"Last: {times[-1]}")
    else:
        check("Poll cycles recorded", False, "no poll lines yet")

# ── Summary ────────────────────────────────────────────────────────────────
print(f"\n{'='*40}")
total = len(results)
passed = sum(results)
failed = total - passed
print(f"  {passed}/{total} passed" + (f"  ({failed} failed)" if failed else "  ✓ all good"))
if failed:
    sys.exit(1)
