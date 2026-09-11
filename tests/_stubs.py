"""Hardware-free stubs to import the audited main.py in isolation.

We fake AppKit / Quartz / Foundation / objc so `import main` succeeds without a
GUI, a display, or PyObjC. The real ctypes.CDLL loads of system frameworks are
harmless (loading a dylib is read-only); every function that would actually
mutate hardware is monkeypatched by the individual tests before it is called.

This lets the reproduction tests exercise the REAL archive code paths rather
than a paraphrase of them.
"""
import sys
import types
from unittest.mock import MagicMock


class _AnyAttrModule(types.ModuleType):
    """A fake module: any attribute access returns a fresh MagicMock, except the
    names explicitly set on it (real classes/constants needed at import time)."""

    def __getattr__(self, name):  # only called for missing attrs
        m = MagicMock(name=f"{self.__name__}.{name}")
        setattr(self, name, m)
        return m


def _base_class(name):
    # A usable base class for `class X(AppKit.NSObject)` / `class P(NSPanel)`.
    return type(name, (object,), {})


def install():
    """Install the stub modules into sys.modules. Idempotent."""
    if "AppKit" in sys.modules and getattr(sys.modules["AppKit"], "_ds_stub", False):
        return

    objc = _AnyAttrModule("objc")
    # @objc.python_method must return the wrapped function unchanged.
    objc.python_method = lambda fn: fn
    objc.NSObject = _base_class("NSObject")
    objc._ds_stub = True
    sys.modules["objc"] = objc

    appkit = _AnyAttrModule("AppKit")
    appkit.NSObject = objc.NSObject
    appkit.NSPanel = _base_class("NSPanel")
    # Numeric-ish constants sometimes combined with | at import-adjacent code.
    for const in (
        "NSControlStateValueOn", "NSControlStateValueOff",
        "NSWindowStyleMaskBorderless", "NSBackingStoreBuffered",
        "NSScreenSaverWindowLevel", "NSBorderlessWindowMask",
        "NSWindowCollectionBehaviorCanJoinAllSpaces",
        "NSWindowCollectionBehaviorStationary",
        "NSWindowCollectionBehaviorFullScreenAuxiliary",
        "NSWindowCollectionBehaviorIgnoresCycle",
        "NSPopUpMenuWindowLevel", "NSWindowCollectionBehaviorTransient",
        "NSEventMaskLeftMouseUp", "NSEventMaskRightMouseUp",
        "NSVisualEffectBlendingModeBehindWindow", "NSVisualEffectStateActive",
        "NSImageScaleProportionallyDown", "NSSquareStatusItemLength",
        "NSApplicationActivationPolicyAccessory", "NSTextAlignmentRight",
        "NSEventTypeRightMouseUp",
    ):
        setattr(appkit, const, 0)
    appkit._ds_stub = True
    sys.modules["AppKit"] = appkit

    quartz = _AnyAttrModule("Quartz")
    quartz._ds_stub = True
    sys.modules["Quartz"] = quartz

    foundation = _AnyAttrModule("Foundation")
    foundation.NSMakeRect = lambda *a: tuple(a)
    foundation.NSMakePoint = lambda *a: tuple(a)
    foundation._ds_stub = True
    sys.modules["Foundation"] = foundation

    return dict(objc=objc, AppKit=appkit, Quartz=quartz, Foundation=foundation)
