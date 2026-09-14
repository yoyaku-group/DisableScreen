#!/usr/bin/env python3
"""E2E smoke checks for the installed DisableScreen app.

A08 fixes: paths are injectable (DISABLESCREEN_APP / DISABLESCREEN_LOG); the
process check matches the exact bundle path; log assertions match the strings the
app actually emits ("Started.", "Displays:"); the removed "Poll:" expectation and
the unproven BetterDisplay assumption are gone; SKIP is distinct from PASS.

Exit code: 0 if no FAIL (SKIPs allowed), 1 if any FAIL.
"""
import os
import subprocess
import sys
from pathlib import Path

APP = Path(os.environ.get("DISABLESCREEN_APP", "/Applications/DisableScreen.app"))
LOG = Path(os.environ.get("DISABLESCREEN_LOG", Path.home() / "DisableScreen" / "disablescreen.log"))

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
fails = 0


def check(name, ok, detail=""):
    global fails
    tag = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
    if not ok:
        fails += 1
    print(f"  [{tag}] {name}" + (f" — {detail}" if detail else ""))


def skip(name, why):
    print(f"  [{YELLOW}SKIP{RESET}] {name} — {why}")


# ── 1. App bundle ────────────────────────────────────────────────────────────
print("\n[1] App bundle")
check("bundle exists", APP.exists(), str(APP))
check("Info.plist exists", (APP / "Contents/Info.plist").exists())
binary = APP / "Contents/MacOS/DisableScreen"
check("launcher binary exists", binary.exists())
if binary.exists():
    check("launcher binary executable", bool(binary.stat().st_mode & 0o111))

# ── 2. Process running (match the EXACT bundle path) ─────────────────────────
print("\n[2] Process")
main_py = str(APP / "Contents/Resources/main.py")
out = subprocess.run(["pgrep", "-f", main_py], capture_output=True, text=True)
if out.returncode == 0:
    check("app process running", True, out.stdout.strip())
else:
    skip("app process running", f"no process for {main_py} (app not launched)")

# ── 3. Log file ──────────────────────────────────────────────────────────────
print("\n[3] Log file")
if LOG.exists():
    content = LOG.read_text(errors="replace")
    check("startup logged", "Started." in content)     # real string, not "App started"
    check("display list logged", "Displays:" in content)
else:
    skip("log file", f"{LOG} absent (app never ran under this HOME)")

# ── 4. Screen detection via CoreGraphics ─────────────────────────────────────
print("\n[4] Screen detection")
try:
    from Quartz import CGDisplayIsBuiltin, CGGetOnlineDisplayList
    err, displays, count = CGGetOnlineDisplayList(16, None, None)
    check("CGGetOnlineDisplayList ok", err == 0, f"{count} display(s)")
    for d in displays:
        check(f"display id={d}", True, f"builtin={bool(CGDisplayIsBuiltin(d))}")
except Exception as e:
    skip("screen detection", f"PyObjC/Quartz unavailable: {e}")

# ── Summary ──────────────────────────────────────────────────────────────────
print("\n" + "=" * 40)
if fails:
    print(f"  {RED}{fails} FAIL{RESET}")
    sys.exit(1)
print(f"  {GREEN}no failures{RESET} (skips are not failures)")
