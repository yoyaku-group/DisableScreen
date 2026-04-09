#!/usr/bin/env python3
"""DisableScreen - Menu bar app to disable MacBook built-in display."""

import AppKit
import objc
import ctypes
import logging
from pathlib import Path
from Quartz import CGDisplayIsBuiltin, CGGetOnlineDisplayList, CGDisplayBounds
from AppKit import (
    NSApp, NSApplication, NSStatusBar, NSMenu, NSMenuItem,
    NSWindow, NSScreen, NSColor, NSImage, NSFont,
    NSTextField, NSImageView, NSView, NSTimer,
    NSWindowStyleMaskBorderless, NSBackingStoreBuffered,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorStationary,
    NSControlStateValueOn, NSControlStateValueOff,
    NSApplicationActivationPolicyAccessory,
    NSSquareStatusItemLength, NSScreenSaverWindowLevel,
    NSImageScaleProportionallyDown,
    NSApplicationDidChangeScreenParametersNotification,
)
from Foundation import NSMakeRect, NSNotificationCenter

LOG_PATH = Path.home() / "DisableScreen" / "disablescreen.log"
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("DisableScreen")

MENU_W = 240

is_disabled = False
disabled_display_id = None
status_item = None

# ── CoreGraphics (public) ──────────────────────────────────────────────────

_cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')

_cg.CGBeginDisplayConfiguration.restype = ctypes.c_int32
_cg.CGBeginDisplayConfiguration.argtypes = [ctypes.POINTER(ctypes.c_void_p)]

_cg.CGCompleteDisplayConfiguration.restype = ctypes.c_int32
_cg.CGCompleteDisplayConfiguration.argtypes = [ctypes.c_void_p, ctypes.c_uint32]

_cg.CGCancelDisplayConfiguration.restype = ctypes.c_int32
_cg.CGCancelDisplayConfiguration.argtypes = [ctypes.c_void_p]

# ── SkyLight (private) — SLSConfigureDisplayEnabled ───────────────────────

try:
    _sls = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
    _sls.SLSConfigureDisplayEnabled.restype = ctypes.c_int32
    _sls.SLSConfigureDisplayEnabled.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_bool]
    log.info("SkyLight loaded OK")
except Exception as e:
    _sls = None
    log.error("SkyLight load FAILED: %s", e)

# ── CoreDisplay brightness (fallback visual only) ──────────────────────────

try:
    _cd = ctypes.CDLL('/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay')
    _cd.CoreDisplay_Display_GetUserBrightness.restype = ctypes.c_double
    _cd.CoreDisplay_Display_GetUserBrightness.argtypes = [ctypes.c_uint32]
    _cd.CoreDisplay_Display_SetUserBrightness.restype = None
    _cd.CoreDisplay_Display_SetUserBrightness.argtypes = [ctypes.c_uint32, ctypes.c_double]
    log.info("CoreDisplay loaded OK")
except Exception as e:
    _cd = None
    log.error("CoreDisplay load FAILED: %s", e)


# ── Display enable/disable via SkyLight ────────────────────────────────────

def _sls_set_display_enabled(display_id: int, enabled: bool) -> bool:
    """Use SLSConfigureDisplayEnabled to add/remove display from active config."""
    config = ctypes.c_void_p()
    err = _cg.CGBeginDisplayConfiguration(ctypes.byref(config))
    if err != 0:
        log.error("[SLS] CGBeginDisplayConfiguration failed: %d", err)
        return False
    err2 = _sls.SLSConfigureDisplayEnabled(
        config, ctypes.c_uint32(display_id), ctypes.c_bool(enabled)
    )
    if err2 != 0:
        log.error("[SLS] SLSConfigureDisplayEnabled(%d, %s) failed: %d", display_id, enabled, err2)
        _cg.CGCancelDisplayConfiguration(config)
        return False
    err3 = _cg.CGCompleteDisplayConfiguration(config, ctypes.c_uint32(0))
    if err3 != 0:
        log.error("[SLS] CGCompleteDisplayConfiguration failed: %d", err3)
        return False
    log.info("[SLS] Display %d enabled=%s → OK", display_id, enabled)
    return True


def get_builtin_display_id() -> int:
    """Return CGDirectDisplayID of built-in. Works even when display is disabled."""
    # Check online (connected) displays — includes displays disabled from active config
    displays_arr = (ctypes.c_uint32 * 16)()
    count = ctypes.c_uint32()
    _cg.CGGetOnlineDisplayList = getattr(_cg, 'CGGetOnlineDisplayList', None)
    try:
        from Quartz import CGGetOnlineDisplayList as _cg_online
        _, displays, n = _cg_online(16, None, None)
        for d in displays:
            if CGDisplayIsBuiltin(d):
                log.debug("[DETECT] Built-in found in online list: ID=%d", d)
                return d
    except Exception:
        pass
    # Apple Silicon fallback: built-in is always ID=1
    if CGDisplayIsBuiltin(1):
        return 1
    log.warning("[DETECT] Built-in ID not found, defaulting to 1")
    return 1


# ── Display utils ──────────────────────────────────────────────────────────

def list_all_displays():
    _, displays, _ = CGGetOnlineDisplayList(16, None, None)
    return [(d, bool(CGDisplayIsBuiltin(d))) for d in displays]


def find_builtin_screen():
    for screen in NSScreen.screens():
        did = screen.deviceDescription().get("NSScreenNumber", 0)
        builtin = bool(CGDisplayIsBuiltin(did))
        f = screen.frame()
        log.debug("  '%s' | ID=%s | builtin=%s | frame=(%.0f,%.0f,%.0fx%.0f)",
                  screen.localizedName(), did, builtin,
                  f.origin.x, f.origin.y, f.size.width, f.size.height)
        if builtin:
            return screen
    return None


def find_external_screen():
    for screen in NSScreen.screens():
        did = screen.deviceDescription().get("NSScreenNumber", 0)
        if not CGDisplayIsBuiltin(did):
            return screen
    return None


# ── Custom menu views ──────────────────────────────────────────────────────

def _sf_image(name):
    return NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)


def make_header_view(name, resolution):
    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, MENU_W, 42))

    icon = NSImageView.alloc().initWithFrame_(NSMakeRect(14, 12, 18, 18))
    icon.setImage_(_sf_image("display"))
    icon.setImageScaling_(NSImageScaleProportionallyDown)
    view.addSubview_(icon)

    name_field = NSTextField.labelWithString_(name)
    name_field.setFrame_(NSMakeRect(40, 14, MENU_W - 46, 16))
    name_field.setFont_(NSFont.boldSystemFontOfSize_(13.0))
    view.addSubview_(name_field)

    if resolution:
        res_field = NSTextField.labelWithString_(resolution)
        res_field.setFrame_(NSMakeRect(40, 2, MENU_W - 46, 12))
        res_field.setFont_(NSFont.systemFontOfSize_(10.0))
        res_field.setTextColor_(NSColor.secondaryLabelColor())
        view.addSubview_(res_field)

    return view


def make_toggle_view(label, icon_name, is_on, target):
    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, MENU_W, 36))

    icon = NSImageView.alloc().initWithFrame_(NSMakeRect(14, 10, 16, 16))
    icon.setImage_(_sf_image(icon_name))
    icon.setImageScaling_(NSImageScaleProportionallyDown)
    view.addSubview_(icon)

    lbl = NSTextField.labelWithString_(label)
    lbl.setFrame_(NSMakeRect(38, 11, 145, 15))
    lbl.setFont_(NSFont.systemFontOfSize_(13.0))
    view.addSubview_(lbl)

    sw = AppKit.NSSwitch.alloc().init()
    sw.setState_(NSControlStateValueOn if is_on else NSControlStateValueOff)
    sw.setTarget_(target)
    sw.setAction_("toggleSwitch:")
    sw_w, sw_h = 44, 22
    sw.setFrame_(NSMakeRect(MENU_W - sw_w - 10, 7, sw_w, sw_h))
    view.addSubview_(sw)

    return view


def make_disabled_toggle_view():
    view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, MENU_W, 36))

    icon = NSImageView.alloc().initWithFrame_(NSMakeRect(14, 10, 16, 16))
    icon.setImage_(_sf_image("laptopcomputer"))
    icon.setImageScaling_(NSImageScaleProportionallyDown)
    icon.setAlphaValue_(0.35)
    view.addSubview_(icon)

    lbl = NSTextField.labelWithString_("Écran intégré")
    lbl.setFrame_(NSMakeRect(38, 11, 145, 15))
    lbl.setFont_(NSFont.systemFontOfSize_(13.0))
    lbl.setTextColor_(NSColor.tertiaryLabelColor())
    view.addSubview_(lbl)

    sw = AppKit.NSSwitch.alloc().init()
    sw.setState_(NSControlStateValueOff)
    sw.setEnabled_(False)
    sw.setFrame_(NSMakeRect(MENU_W - 54, 7, 44, 22))
    view.addSubview_(sw)

    return view


# ── Menu builder ───────────────────────────────────────────────────────────

def ensure_status_item():
    """Re-create status item if it was lost during display reconfiguration."""
    global status_item
    if status_item is None or status_item.button() is None:
        log.info("[UI] Re-creating status item after display change")
        status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(
            NSSquareStatusItemLength
        )


def refresh_ui():
    ensure_status_item()
    if status_item is None:
        return

    symbol = "display.slash" if is_disabled else "display"
    status_item.button().setImage_(_sf_image(symbol))

    log.debug("--- Screen scan ---")
    external = find_external_screen()
    builtin  = find_builtin_screen()

    # Check if built-in hardware exists even if not in active config (disabled by us or BetterDisplay)
    _, online_displays, _ = CGGetOnlineDisplayList(16, None, None)
    builtin_online = any(CGDisplayIsBuiltin(d) for d in online_displays)

    menu = NSMenu.alloc().init()
    menu.setMinimumWidth_(MENU_W)

    if external:
        f = external.frame()
        res = f"{int(f.size.width)}×{int(f.size.height)}"
        h_item = NSMenuItem.alloc().init()
        h_item.setView_(make_header_view(external.localizedName(), res))
        h_item.setEnabled_(False)
        menu.addItem_(h_item)
        menu.addItem_(NSMenuItem.separatorItem())

    t_item = NSMenuItem.alloc().init()
    # Show enabled toggle if: built-in is in active config, OR we disabled it (is_disabled=True)
    # Show disabled toggle only if no built-in hardware at all (no external + no builtin = can't disable)
    can_toggle = builtin is not None or is_disabled
    if can_toggle:
        t_item.setView_(make_toggle_view(
            "Écran intégré", "laptopcomputer",
            not is_disabled, AppDelegate.shared
        ))
    else:
        t_item.setView_(make_disabled_toggle_view())
    menu.addItem_(t_item)

    menu.addItem_(NSMenuItem.separatorItem())
    q = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Quitter", "terminate:", "q")
    q.setTarget_(NSApp)
    menu.addItem_(q)

    status_item.setMenu_(menu)


# ── App delegate ───────────────────────────────────────────────────────────

class AppDelegate(AppKit.NSObject):
    shared = None

    def applicationDidFinishLaunching_(self, notification):
        AppDelegate.shared = self
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

        global status_item
        status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(
            NSSquareStatusItemLength
        )

        log.info("App started. Displays: %s", list_all_displays())
        log.info("SkyLight: %s | CoreDisplay: %s", _sls is not None, _cd is not None)
        refresh_ui()

        # Listen for display reconfiguration to restore the status item
        NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "screensDidChange:", NSApplicationDidChangeScreenParametersNotification, None
        )

        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            5.0, self, "pollScreens:", None, True
        )

    def applicationWillTerminate_(self, notification):
        # Re-enable built-in on quit if we disabled it
        if is_disabled and disabled_display_id is not None:
            log.info("[QUIT] Re-enabling display %d before exit", disabled_display_id)
            _sls_set_display_enabled(disabled_display_id, True)

    def screensDidChange_(self, notification):
        log.info("[SCREENS] Display configuration changed — refreshing UI")
        # Small delay so macOS finishes reconfiguring before we query screen state
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, self, "delayedRefresh:", None, False
        )

    def delayedRefresh_(self, timer):
        refresh_ui()

    def pollScreens_(self, timer):
        displays = list_all_displays()
        log.debug("Poll: %d display(s) | builtin=%s | disabled=%s",
                  len(displays), any(b for _, b in displays), is_disabled)
        refresh_ui()

    def toggleSwitch_(self, sender):
        new_state = sender.state()
        log.info("Switch → %s", "ON (enable)" if new_state == NSControlStateValueOn else "OFF (disable)")
        if new_state == NSControlStateValueOff:
            self._disable()
        else:
            self._enable()

    @objc.python_method
    def _disable(self):
        global is_disabled, disabled_display_id

        log.debug("--- Screen scan ---")
        builtin_screen = find_builtin_screen()
        did = get_builtin_display_id()

        log.info("[DISABLE] builtin_screen=%s display_id=%d",
                 builtin_screen.localizedName() if builtin_screen else "None", did)

        if builtin_screen is None:
            log.warning("[DISABLE] Built-in not in active config — cannot disable")
            refresh_ui()
            return

        # Remove built-in from active display configuration (macOS handles fade animation)
        ok = _sls_set_display_enabled(did, False)
        log.info("[DISABLE] SLS disable: %s", ok)

        if not ok:
            log.error("[DISABLE] FAILED")
            refresh_ui()
            return

        disabled_display_id = did
        is_disabled = True
        log.info("[DISABLE] ✓ COMPLETE — display_id=%d removed from active config", did)
        refresh_ui()
        # Refresh again after macOS finishes moving menu bar to external display
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "delayedRefresh:", None, False
        )

    @objc.python_method
    def _enable(self):
        global is_disabled, disabled_display_id

        did = disabled_display_id if disabled_display_id else get_builtin_display_id()
        log.info("[ENABLE] Re-enabling display_id=%d", did)

        ok = _sls_set_display_enabled(did, True)
        log.info("[ENABLE] SLS enable: %s", ok)

        if not ok:
            log.error("[ENABLE] FAILED")
            refresh_ui()
            return

        disabled_display_id = None
        is_disabled = False
        log.info("[ENABLE] ✓ COMPLETE")
        refresh_ui()
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "delayedRefresh:", None, False
        )


# ── Entry point ────────────────────────────────────────────────────────────

if __name__ == "__main__":
    log.info("DisableScreen launching...")
    app = NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    app.run()
