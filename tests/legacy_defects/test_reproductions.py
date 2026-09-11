"""Eight reproductions of the audited defects (A01–A10, A17) in main.py.

A PASSING test here means the defect is PRESENT in the audited archive. These
run against the archive revision extracted from git, so they keep passing on the
archive even after Phase 1 fixes land on the working tree. `tests/test_main_fixed.py`
holds the INVERSE assertions against the fixed working-tree main.py.

Hardware-free: system frameworks are stubbed; every hardware-mutating backend is
monkeypatched to a fake before it is exercised.
"""
import importlib.util
import logging
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve()
REPO = HERE.parents[2]
ARCHIVE_SHA = "a7665b5b9d1435aab9448a2758f42a8db00cb152"

sys.path.insert(0, str(REPO / "tests"))
import _stubs  # noqa: E402


def _archive_source() -> str:
    return subprocess.check_output(
        ["git", "-C", str(REPO), "show", f"{ARCHIVE_SHA}:main.py"], text=True
    )


def _load_archive_main():
    """Import the archive main.py as a fresh module with GUI stubs installed and
    a temp HOME so the module-level FileHandler can be constructed for tests that
    need the imported module (log dir is pre-created here on purpose)."""
    _stubs.install()
    tmp_home = tempfile.mkdtemp(prefix="ds_home_")
    (pathlib.Path(tmp_home) / "DisableScreen").mkdir(parents=True, exist_ok=True)
    old_home = os.environ.get("HOME")
    os.environ["HOME"] = tmp_home
    src = _archive_source()
    path = pathlib.Path(tmp_home) / "main_archive.py"
    path.write_text(src)
    try:
        spec = importlib.util.spec_from_file_location("main_archive", path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["main_archive"] = mod
        spec.loader.exec_module(mod)
    finally:
        if old_home is not None:
            os.environ["HOME"] = old_home
    return mod


class ArchiveDefectReproductions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = _archive_source()

    # A01 — FileHandler built before its parent directory exists.
    def test_01_first_launch_log_parent_not_created(self):
        home = tempfile.mkdtemp(prefix="ds_neuf_")  # NO ~/DisableScreen inside
        log_path = pathlib.Path(home) / "DisableScreen" / "disablescreen.log"
        # This is exactly what main.py does at import: FileHandler(LOG_PATH)
        # with no prior mkdir. On a fresh HOME it raises.
        with self.assertRaises(FileNotFoundError):
            logging.FileHandler(log_path)
        # And the archive source indeed builds it before any mkdir.
        self.assertIn("handlers=[logging.FileHandler(LOG_PATH)", self.src)
        self.assertNotIn("LOG_PATH.parent.mkdir", self.src.split("basicConfig")[0])

    # A02 — brightness write is broadcast to every IODisplayConnect service.
    def test_02_iokit_brightness_writes_every_matching_service(self):
        mod = _load_archive_main()
        writes = []

        class FakeIOKit:
            def IOServiceMatching(self, name):
                return 1

            def IOServiceGetMatchingServices(self, port, match, it_ref):
                it_ref._obj.value = 100  # iterator handle
                return 0

            def IOIteratorNext(self, it):
                # yield services 201, 202, then 0 (two external monitors)
                FakeIOKit._seq = getattr(FakeIOKit, "_seq", [201, 202, 0])
                return FakeIOKit._seq.pop(0)

            def IODisplaySetFloatParameter(self, svc, a, key, val):
                writes.append(svc)
                return 0

            def IOObjectRelease(self, x):
                return 0

        class FakeCF:
            def CFStringCreateWithCString(self, *a):
                return 1

            def CFRelease(self, *a):
                return None

        mod._iokit = FakeIOKit()
        mod._cf = FakeCF()
        ok = mod._iokit_brightness(0.5)
        self.assertTrue(ok)
        # Defect: a single brightness request hit BOTH monitors.
        self.assertEqual(writes, [201, 202])

    # A03 — set_display_resolution returns True even when native calls fail.
    def test_03_resolution_returns_success_when_all_native_calls_fail(self):
        mod = _load_archive_main()

        class FakeMode:
            def __init__(self, w, h, r):
                self.w, self.h, self.r = w, h, r

        mod.CGDisplayCopyAllDisplayModes = lambda did, opt: [FakeMode(1920, 1080, 60)]
        mod.CGDisplayModeGetWidth = lambda m: m.w
        mod.CGDisplayModeGetHeight = lambda m: m.h
        mod.CGDisplayModeGetRefreshRate = lambda m: m.r
        mod.CGDisplaySetDisplayMode = lambda *a: 9999  # failure code (ignored!)

        class FakeCG:
            def CGBeginDisplayConfiguration(self, ref):
                return 1  # failure (ignored!)

            def CGCompleteDisplayConfiguration(self, cfg, opt):
                return 1  # failure (ignored!)

            def CGCancelDisplayConfiguration(self, cfg):
                return 0

        mod._cg = FakeCG()
        # Defect: returns True despite begin/set/complete all failing.
        self.assertTrue(mod.set_display_resolution(1, 1920, 1080))

    # A04/A07 — external brightness cache stores requested value, not applied floor.
    def test_04_zero_brightness_state_does_not_match_applied_floor(self):
        mod = _load_archive_main()
        applied = {}

        def fake_apply_dim(did, value):
            applied[did] = max(0.08, min(1.0, value))  # real code's floor
            return True

        mod._apply_dim = fake_apply_dim
        mod._iokit = None
        mod._cf = None
        mod.CGDisplayIsBuiltin = lambda did: 0  # external
        # Overlay clamps at 0.08 floor; but cache stores raw 0.0.
        mod.set_display_brightness(777, 0.0)
        self.assertAlmostEqual(applied[777], 0.08)  # what the pixels show
        self.assertEqual(mod._sw_brightness.get(777), 0.0)
        # The applied floor is 0.08 → UI cache (0.0) misrepresents reality.
        self.assertNotAlmostEqual(mod._sw_brightness.get(777), 0.08)

    # A06 — launcher path accepts a Python bundle without identity check.
    def test_05_launcher_path_accepts_python_bundle_without_identity_check(self):
        mod = _load_archive_main()
        py_exec = "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"

        class FakeBundle:
            def executablePath(self):
                return py_exec

            def bundleIdentifier(self):
                return "org.python.python"

        mod.NSBundle = type("NSBundle", (), {"mainBundle": staticmethod(lambda: FakeBundle())})
        # Defect: returns the Python interpreter path, no bundle-id/name check.
        self.assertEqual(mod._launcher_path(), py_exec)

    # A03 — clean termination re-enables displays but never restores sleep policy.
    def test_06_clean_termination_has_no_sleep_policy_cleanup(self):
        mod = _load_archive_main()
        calls = {"lid": 0, "sls": []}
        mod._set_lid_stay_awake = lambda enabled: calls.__setitem__("lid", calls["lid"] + 1)
        mod._sls_set_display_enabled = lambda did, en: (calls["sls"].append((did, en)), True)[1]
        mod.disabled_displays.clear()
        mod.disabled_displays[5] = True
        delegate = mod.AppDelegate.alloc().init() if hasattr(mod.AppDelegate, "alloc") else mod.AppDelegate()
        mod.AppDelegate.applicationWillTerminate_(delegate, None)
        # Displays restored…
        self.assertIn((5, True), calls["sls"])
        # …but sleep policy never touched on quit (the defect).
        self.assertEqual(calls["lid"], 0)
        self.assertNotIn("disablesleep", self.src.split("applicationWillTerminate_")[1][:400])

    # A04 — last-display guard is absent in the action handler.
    def test_07_last_display_guard_is_missing_in_action_handler(self):
        mod = _load_archive_main()
        disabled = []
        mod._sls_set_display_enabled = lambda did, en: (disabled.append((did, en)), True)[1]
        mod.ensure_status_item = lambda d: None
        mod.NSTimer = type("T", (), {"scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_": staticmethod(lambda *a: None)})

        class FakeScreen:
            def deviceDescription(self):
                return {"NSScreenNumber": 42}

        mod.NSScreen = type("NSScreen", (), {"screens": staticmethod(lambda: [FakeScreen()])})

        class FakeSender:
            def tag(self):
                return 42

            def state(self):
                return mod.NSControlStateValueOff  # user turning it OFF

        delegate = mod.AppDelegate.alloc().init() if hasattr(mod.AppDelegate, "alloc") else mod.AppDelegate()
        mod.disabled_displays.clear()
        mod.AppDelegate.toggleDisplay_(delegate, FakeSender())
        # Defect: the ONLY active display (42) gets disabled — no count guard at action time.
        self.assertIn((42, False), disabled)

    # A08 — e2e expectations reference log strings the current source never emits.
    def test_08_e2e_log_expectations_do_not_match_current_source(self):
        e2e = subprocess.check_output(
            ["git", "-C", str(REPO), "show", f"{ARCHIVE_SHA}:test_e2e.py"], text=True
        )
        self.assertIn('"App started" in content', e2e)
        self.assertIn('"Poll:" in content', e2e)
        # main.py logs "Started." (not "App started") and has no "Poll:" line.
        self.assertNotIn("App started", self.src)
        self.assertNotIn("Poll:", self.src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
