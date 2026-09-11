"""Inverse assertions against the FIXED working-tree main.py (Phase 1, G1).

Where tests/legacy_defects proved a defect PRESENT in the archive, these prove it
GONE in the current source. Hardware-free: frameworks stubbed, backends faked.
"""
import importlib.util
import logging
import os
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve()
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tests"))
import _stubs  # noqa: E402


def _load_fixed_main():
    _stubs.install()
    tmp_home = tempfile.mkdtemp(prefix="ds_fixed_")
    (pathlib.Path(tmp_home) / "DisableScreen").mkdir(parents=True, exist_ok=True)
    old_home = os.environ.get("HOME")
    os.environ["HOME"] = tmp_home
    try:
        spec = importlib.util.spec_from_file_location("main_fixed", REPO / "main.py")
        mod = importlib.util.module_from_spec(spec)
        sys.modules["main_fixed"] = mod
        spec.loader.exec_module(mod)
    finally:
        if old_home is not None:
            os.environ["HOME"] = old_home
    mod._TMP_HOME = tmp_home
    return mod


class FixedBehaviour(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = (REPO / "main.py").read_text()

    # A01 — log dir is created before the FileHandler; fresh HOME must not crash.
    def test_a01_fresh_home_creates_log_dir(self):
        self.assertIn("LOG_PATH.parent.mkdir(parents=True, exist_ok=True)", self.src)
        # And the mkdir precedes basicConfig in source order.
        self.assertLess(self.src.index("LOG_PATH.parent.mkdir"), self.src.index("logging.basicConfig"))

    # A02 — no broadcast write path remains; brightness read is read-only.
    def test_a02_no_iokit_broadcast_write(self):
        mod = _load_fixed_main()
        self.assertFalse(hasattr(mod, "_iokit_brightness"))          # old writer gone
        self.assertTrue(hasattr(mod, "_iokit_brightness_readonly"))  # diagnostic only
        self.assertNotIn(".IODisplaySetFloatParameter", self.src)    # write symbol never declared/called

    # A05 — resolution returns a typed result; failure is not success.
    def test_a05_resolution_failure_is_not_success(self):
        mod = _load_fixed_main()

        class FakeMode:
            def __init__(s, w, h, r): s.w, s.h, s.r = w, h, r

        mod.CGDisplayCopyAllDisplayModes = lambda d, o: [FakeMode(1920, 1080, 60)]
        mod.CGDisplayModeGetWidth = lambda m: m.w
        mod.CGDisplayModeGetHeight = lambda m: m.h
        mod.CGDisplayModeGetRefreshRate = lambda m: m.r
        mod.CGDisplaySetDisplayMode = lambda *a: 9999  # native failure
        res = mod.set_display_resolution(1, 1920, 1080)
        self.assertIsInstance(res, dict)
        self.assertFalse(res["ok"])
        self.assertEqual(res["native_rc"], 9999)

    def test_a05_resolution_ok_only_on_readback_match(self):
        mod = _load_fixed_main()

        class FakeMode:
            def __init__(s, w, h, r): s.w, s.h, s.r = w, h, r

        mod.CGDisplayCopyAllDisplayModes = lambda d, o: [FakeMode(1920, 1080, 60)]
        mod.CGDisplayModeGetWidth = lambda m: m.w
        mod.CGDisplayModeGetHeight = lambda m: m.h
        mod.CGDisplayModeGetRefreshRate = lambda m: m.r
        mod.CGDisplaySetDisplayMode = lambda *a: 0            # native ok
        mod.get_current_resolution = lambda d: "1920x1080"    # readback matches
        self.assertTrue(mod.set_display_resolution(1, 1920, 1080)["ok"])
        mod.get_current_resolution = lambda d: "1280x720"     # readback mismatch
        self.assertFalse(mod.set_display_resolution(1, 1920, 1080)["ok"])

    # A06 — launcher path refuses a Python bundle.
    def test_a06_launcher_rejects_python_bundle(self):
        mod = _load_fixed_main()

        class FakeBundle:
            def executablePath(self):
                return "/…/Python.app/Contents/MacOS/Python"

            def bundleIdentifier(self):
                return "org.python.python"

        mod.NSBundle = type("NSBundle", (), {"mainBundle": staticmethod(lambda: FakeBundle())})
        # Wrong identity → not the python path; falls back to install path or None.
        self.assertNotIn("Python", str(mod._launcher_path() or ""))

    # A07 — external brightness cache stores the applied (floored) value.
    def test_a07_external_cache_equals_applied_floor(self):
        mod = _load_fixed_main()
        mod._ensure_dim_window = lambda did: type("W", (), {"setAlphaValue_": lambda s, v: None})()
        mod._iokit = None
        mod._cf = None
        mod.CGDisplayIsBuiltin = lambda did: 0
        mod.set_display_brightness(777, 0.0)
        self.assertAlmostEqual(mod._sw_brightness.get(777), mod.DIM_FLOOR)

    # A03 — clean termination restores disablesleep ONLY if we own it.
    def test_a03_quit_restores_only_owned_lid(self):
        mod = _load_fixed_main()
        calls = []
        mod._pmset_disablesleep = lambda v: calls.append(v) or 0
        mod._current_boot_uuid = lambda: "BOOT-A"
        # Not owned → quit must not touch the flag.
        mod._write_lid_owner(None)
        mod._restore_owned_lid_on_quit()
        self.assertEqual(calls, [])
        # Owned, same boot, flag reads ON → quit restores to 0.
        mod._write_lid_owner({"prev": False, "boot_uuid": "BOOT-A", "set_at": 0})
        mod._lid_stay_awake_state = lambda: True
        mod._restore_owned_lid_on_quit()
        self.assertEqual(calls, ["0"])

    def test_a03_quit_ignores_other_boot_owner(self):
        mod = _load_fixed_main()
        calls = []
        mod._pmset_disablesleep = lambda v: calls.append(v) or 0
        mod._current_boot_uuid = lambda: "BOOT-NEW"
        mod._write_lid_owner({"prev": False, "boot_uuid": "BOOT-OLD", "set_at": 0})
        mod._lid_stay_awake_state = lambda: True
        mod._restore_owned_lid_on_quit()
        self.assertEqual(calls, [])  # stale owner from another boot → never touch

    # A10 — lid state is tri-state; missing key is None, not False.
    def test_a10_lid_state_tristate_none_on_missing_key(self):
        mod = _load_fixed_main()
        import subprocess as _sp
        mod.subprocess = type("S", (), {"check_output": staticmethod(lambda *a, **k: "Sleep 1\nother 0\n")})
        self.assertIsNone(mod._lid_stay_awake_state())  # no SleepDisabled line → None
        mod.subprocess = _sp

    # A08 — e2e no longer asserts on "Poll:"/"App started" and uses "Started.".
    def test_a08_e2e_matches_real_log_strings(self):
        e2e = (REPO / "test_e2e.py").read_text()
        self.assertNotIn('"Poll:" in content', e2e)
        self.assertNotIn('"App started" in content', e2e)
        self.assertIn('"Started." in content', e2e)


if __name__ == "__main__":
    unittest.main(verbosity=2)
