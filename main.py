#!/usr/bin/env python3
"""DisableScreen — Multi-display management menu bar app."""

import AppKit
import objc
import ctypes
import logging
import subprocess
from pathlib import Path
from Quartz import (
    CGDisplayIsBuiltin, CGGetOnlineDisplayList, CGDisplayBounds,
    CGDisplayCopyAllDisplayModes, CGDisplaySetDisplayMode,
    CGDisplayCopyDisplayMode, CGDisplayModeGetWidth,
    CGDisplayModeGetHeight, CGDisplayModeGetRefreshRate,
)
from AppKit import (
    NSApp, NSApplication, NSStatusBar, NSMenu, NSMenuItem,
    NSScreen, NSColor, NSImage, NSFont, NSTextField, NSImageView,
    NSView, NSTimer, NSSlider, NSButton, NSPopUpButton,
    NSControlStateValueOn, NSControlStateValueOff,
    NSApplicationActivationPolicyAccessory, NSSquareStatusItemLength,
    NSImageScaleProportionallyDown,
    NSApplicationDidChangeScreenParametersNotification,
    NSTextAlignmentRight,
)
from Foundation import NSMakeRect, NSNotificationCenter

LOG_PATH = Path.home() / "DisableScreen" / "disablescreen.log"
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler()],
)
log = logging.getLogger("DisableScreen")

MENU_W = 280

# State: display_id -> bool (True = disabled by us)
disabled_displays = {}
status_item = None

# ── CoreGraphics ──────────────────────────────────────────────────────────────
_cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
_cg.CGBeginDisplayConfiguration.restype = ctypes.c_int32
_cg.CGBeginDisplayConfiguration.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
_cg.CGCompleteDisplayConfiguration.restype = ctypes.c_int32
_cg.CGCompleteDisplayConfiguration.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
_cg.CGCancelDisplayConfiguration.restype = ctypes.c_int32
_cg.CGCancelDisplayConfiguration.argtypes = [ctypes.c_void_p]

# ── SkyLight ──────────────────────────────────────────────────────────────────
try:
    _sls = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
    _sls.SLSConfigureDisplayEnabled.restype = ctypes.c_int32
    _sls.SLSConfigureDisplayEnabled.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_bool]
    log.info("SkyLight loaded OK")
except Exception as e:
    _sls = None
    log.error("SkyLight load FAILED: %s", e)

# ── CoreDisplay (brightness) ──────────────────────────────────────────────────
_cd = None
_ds_get_brightness = None
_ds_set_brightness = None
try:
    _cd = ctypes.CDLL('/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay')
    _cd.CoreDisplay_Display_GetUserBrightness.restype = ctypes.c_double
    _cd.CoreDisplay_Display_GetUserBrightness.argtypes = [ctypes.c_uint32]
    _cd.CoreDisplay_Display_SetUserBrightness.restype = None
    _cd.CoreDisplay_Display_SetUserBrightness.argtypes = [ctypes.c_uint32, ctypes.c_double]
    # DisplayServices — works on more display types
    _ds_get = _cd.DisplayServicesGetBrightness
    _ds_get.restype = ctypes.c_int32
    _ds_get.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_float)]
    _ds_set = _cd.DisplayServicesSetBrightness
    _ds_set.restype = ctypes.c_int32
    _ds_set.argtypes = [ctypes.c_uint32, ctypes.c_float]
    _ds_get_brightness = _ds_get
    _ds_set_brightness = _ds_set
    log.info("CoreDisplay + DisplayServices loaded OK")
except Exception as e:
    log.error("CoreDisplay load FAILED: %s", e)


def get_display_brightness(display_id: int) -> float:
    """Return brightness 0.0–1.0, or -1.0 if unsupported."""
    if _ds_get_brightness:
        try:
            val = ctypes.c_float(0.0)
            err = _ds_get_brightness(ctypes.c_uint32(display_id), ctypes.byref(val))
            if err == 0 and 0.0 <= val.value <= 1.0:
                return float(val.value)
        except Exception:
            pass
    if _cd:
        try:
            val = _cd.CoreDisplay_Display_GetUserBrightness(ctypes.c_uint32(display_id))
            if 0.0 <= val <= 1.0:
                return float(val)
        except Exception:
            pass
    return -1.0


def set_display_brightness(display_id: int, value: float):
    value = max(0.0, min(1.0, value))
    if _ds_set_brightness:
        try:
            if _ds_set_brightness(ctypes.c_uint32(display_id), ctypes.c_float(value)) == 0:
                return
        except Exception:
            pass
    if _cd:
        try:
            _cd.CoreDisplay_Display_SetUserBrightness(ctypes.c_uint32(display_id), ctypes.c_double(value))
        except Exception:
            pass


# ── Display enable / disable ──────────────────────────────────────────────────
def _sls_set_display_enabled(display_id: int, enabled: bool) -> bool:
    if not _sls:
        return False
    config = ctypes.c_void_p()
    if _cg.CGBeginDisplayConfiguration(ctypes.byref(config)) != 0:
        return False
    err = _sls.SLSConfigureDisplayEnabled(config, ctypes.c_uint32(display_id), ctypes.c_bool(enabled))
    if err != 0:
        _cg.CGCancelDisplayConfiguration(config)
        log.error("[SLS] SLSConfigureDisplayEnabled failed: %d", err)
        return False
    if _cg.CGCompleteDisplayConfiguration(config, ctypes.c_uint32(0)) != 0:
        return False
    log.info("[SLS] display %d enabled=%s OK", display_id, enabled)
    return True


# ── Resolution helpers ────────────────────────────────────────────────────────
def get_current_resolution(display_id: int) -> str:
    try:
        mode = CGDisplayCopyDisplayMode(display_id)
        if mode:
            return f"{int(CGDisplayModeGetWidth(mode))}×{int(CGDisplayModeGetHeight(mode))}"
    except Exception:
        pass
    return "—"


def get_display_modes(display_id: int):
    """Return unique (width, height, best_refresh) tuples, largest first, max 20."""
    try:
        modes = CGDisplayCopyAllDisplayModes(display_id, None)
        if not modes:
            return []
        best = {}  # (w, h) -> max refresh
        for m in modes:
            w = int(CGDisplayModeGetWidth(m))
            h = int(CGDisplayModeGetHeight(m))
            r = CGDisplayModeGetRefreshRate(m)
            if w > 0 and h > 0:
                if (w, h) not in best or r > best[(w, h)]:
                    best[(w, h)] = r
        result = sorted([(w, h, r) for (w, h), r in best.items()], key=lambda x: (-x[0], -x[1]))
        return result[:20]
    except Exception as e:
        log.error("get_display_modes: %s", e)
        return []


def set_display_resolution(display_id: int, width: int, height: int, refresh: float) -> bool:
    try:
        modes = CGDisplayCopyAllDisplayModes(display_id, None)
        best_mode = None
        best_r = -1.0
        for m in modes:
            w = int(CGDisplayModeGetWidth(m))
            h = int(CGDisplayModeGetHeight(m))
            r = CGDisplayModeGetRefreshRate(m)
            if w == width and h == height and r >= best_r:
                best_mode = m
                best_r = r
        if best_mode is not None:
            config = ctypes.c_void_p()
            _cg.CGBeginDisplayConfiguration(ctypes.byref(config))
            CGDisplaySetDisplayMode(display_id, best_mode, None)
            _cg.CGCompleteDisplayConfiguration(config, ctypes.c_uint32(0))
            log.info("[RES] Set %dx%d on display %d", width, height, display_id)
            return True
    except Exception as e:
        log.error("set_display_resolution: %s", e)
    return False


# ── Display info ──────────────────────────────────────────────────────────────
def list_all_online_displays():
    _, displays, _ = CGGetOnlineDisplayList(16, None, None)
    return list(displays)


def get_display_name(display_id: int) -> str:
    for screen in NSScreen.screens():
        if screen.deviceDescription().get("NSScreenNumber", 0) == display_id:
            name = screen.localizedName()
            if name:
                return name
    return f"Display {display_id}"


def _sf(name):
    return NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)


# ── Card builder ──────────────────────────────────────────────────────────────
H_HEADER     = 44
H_DDC        = 36
H_BRIGHTNESS = 34
H_RESOLUTION = 34
H_PAD        = 6


def make_display_card(display_id: int, delegate) -> NSView:
    builtin = bool(CGDisplayIsBuiltin(display_id))
    is_dis  = disabled_displays.get(display_id, False)
    name    = "Écran intégré" if builtin else get_display_name(display_id)

    brightness = -1.0
    resolution = "—"
    modes = []

    if not is_dis:
        brightness = get_display_brightness(display_id)
        resolution = get_current_resolution(display_id)
        modes      = get_display_modes(display_id)

    has_brightness = brightness >= 0.0

    # Card height
    card_h = H_HEADER
    if not is_dis:
        if not builtin:
            card_h += H_DDC
        if has_brightness:
            card_h += H_BRIGHTNESS
        card_h += H_RESOLUTION
    card_h += H_PAD

    card = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, MENU_W, card_h))
    y = card_h - H_HEADER  # top row y (macOS coords: bottom=0)

    # ── Header ────────────────────────────────────────────────────────────────
    icon = NSImageView.alloc().initWithFrame_(NSMakeRect(14, y + 13, 18, 18))
    icon.setImage_(_sf("laptopcomputer" if builtin else "display"))
    icon.setImageScaling_(NSImageScaleProportionallyDown)
    if is_dis:
        icon.setAlphaValue_(0.35)
    card.addSubview_(icon)

    name_f = NSTextField.labelWithString_(name)
    name_f.setFrame_(NSMakeRect(40, y + 15, MENU_W - 105, 16))
    name_f.setFont_(NSFont.boldSystemFontOfSize_(13.0))
    if is_dis:
        name_f.setTextColor_(NSColor.tertiaryLabelColor())
    card.addSubview_(name_f)

    if not is_dis and resolution != "—":
        sub = NSTextField.labelWithString_(resolution)
        sub.setFrame_(NSMakeRect(40, y + 3, 120, 11))
        sub.setFont_(NSFont.systemFontOfSize_(10.0))
        sub.setTextColor_(NSColor.secondaryLabelColor())
        card.addSubview_(sub)

    # Toggle switch
    active_count = sum(
        1 for d in list_all_online_displays()
        if not disabled_displays.get(d, False)
    )
    sw = AppKit.NSSwitch.alloc().init()
    sw.setState_(NSControlStateValueOff if is_dis else NSControlStateValueOn)
    sw.setTag_(display_id)
    sw.setTarget_(delegate)
    sw.setAction_("toggleDisplay:")
    if not is_dis and active_count <= 1:
        sw.setEnabled_(False)
    sw.setFrame_(NSMakeRect(MENU_W - 54, y + 11, 44, 22))
    card.addSubview_(sw)

    if is_dis:
        return card

    # ── DDC button (external displays only) ───────────────────────────────────
    if not builtin:
        y -= H_DDC
        btn = NSButton.alloc().initWithFrame_(NSMakeRect(14, y + 6, MENU_W - 28, 24))
        btn.setTitle_("Cliquez ici pour configurer DDC...")
        btn.setBezelStyle_(1)  # NSBezelStyleRounded
        btn.setFont_(NSFont.systemFontOfSize_(11.0))
        btn.setTag_(display_id)
        btn.setTarget_(delegate)
        btn.setAction_("openDDCConfig:")
        try:
            btn.setContentTintColor_(NSColor.systemBlueColor())
        except Exception:
            pass
        card.addSubview_(btn)

    # ── Brightness slider ─────────────────────────────────────────────────────
    if has_brightness:
        y -= H_BRIGHTNESS
        sun = NSImageView.alloc().initWithFrame_(NSMakeRect(14, y + 10, 14, 14))
        sun.setImage_(_sf("sun.min"))
        sun.setImageScaling_(NSImageScaleProportionallyDown)
        card.addSubview_(sun)

        pct_lbl = NSTextField.labelWithString_(f"{int(brightness * 100)}%")
        pct_lbl.setFrame_(NSMakeRect(MENU_W - 42, y + 11, 28, 13))
        pct_lbl.setFont_(NSFont.systemFontOfSize_(11.0))
        pct_lbl.setAlignment_(NSTextAlignmentRight)
        card.addSubview_(pct_lbl)

        slider = NSSlider.alloc().initWithFrame_(NSMakeRect(34, y + 10, MENU_W - 82, 14))
        slider.setMinValue_(0.0)
        slider.setMaxValue_(1.0)
        slider.setDoubleValue_(brightness)
        slider.setTag_(display_id)
        slider.setTarget_(delegate)
        slider.setAction_("adjustBrightness:")
        slider.setContinuous_(True)
        card.addSubview_(slider)

    # ── Resolution row ────────────────────────────────────────────────────────
    y -= H_RESOLUTION
    res_icon = NSImageView.alloc().initWithFrame_(NSMakeRect(14, y + 10, 14, 14))
    res_icon.setImage_(_sf("aspectratio"))
    res_icon.setImageScaling_(NSImageScaleProportionallyDown)
    card.addSubview_(res_icon)

    if modes:
        popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(34, y + 6, MENU_W - 48, 22), False
        )
        popup.setFont_(NSFont.systemFontOfSize_(11.5))
        # Parse current resolution for selection
        cur_parts = resolution.split("×") if "×" in resolution else []
        cur_w = int(cur_parts[0]) if len(cur_parts) >= 2 else 0
        cur_h = int(cur_parts[1]) if len(cur_parts) >= 2 else 0
        sel = 0
        for i, (w, h, r) in enumerate(modes):
            label = f"{w}×{h}" + (f"  @{int(r)}Hz" if r > 0 else "")
            popup.addItemWithTitle_(label)
            if w == cur_w and h == cur_h:
                sel = i
        popup.selectItemAtIndex_(sel)
        popup.setTag_(display_id)
        popup.setTarget_(delegate)
        popup.setAction_("changeResolution:")
        card.addSubview_(popup)
    else:
        res_lbl = NSTextField.labelWithString_(resolution)
        res_lbl.setFrame_(NSMakeRect(34, y + 11, MENU_W - 48, 14))
        res_lbl.setFont_(NSFont.systemFontOfSize_(12.0))
        card.addSubview_(res_lbl)

    return card


# ── Status item & menu ────────────────────────────────────────────────────────
def ensure_status_item():
    global status_item
    if status_item is None or status_item.button() is None:
        log.info("[UI] Re-creating status item")
        status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSSquareStatusItemLength)


def refresh_ui():
    ensure_status_item()
    if not status_item:
        return

    any_disabled = any(disabled_displays.values())
    status_item.button().setImage_(_sf("display.slash" if any_disabled else "display"))

    all_displays = list_all_online_displays()
    log.debug("[UI] refresh: %d online displays", len(all_displays))

    # Sort: external first, built-in last
    all_displays.sort(key=lambda d: (1 if CGDisplayIsBuiltin(d) else 0, d))

    menu = NSMenu.alloc().init()
    menu.setMinimumWidth_(MENU_W)
    menu.setAutoenablesItems_(False)

    for i, did in enumerate(all_displays):
        card = make_display_card(did, AppDelegate.shared)
        item = NSMenuItem.alloc().init()
        item.setView_(card)
        item.setEnabled_(True)
        menu.addItem_(item)
        if i < len(all_displays) - 1:
            menu.addItem_(NSMenuItem.separatorItem())

    menu.addItem_(NSMenuItem.separatorItem())
    q = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Quitter", "terminate:", "q")
    q.setTarget_(NSApp)
    menu.addItem_(q)

    status_item.setMenu_(menu)


# ── AppDelegate ───────────────────────────────────────────────────────────────
class AppDelegate(AppKit.NSObject):
    shared = None

    def applicationDidFinishLaunching_(self, notification):
        AppDelegate.shared = self
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        global status_item
        status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSSquareStatusItemLength)
        log.info("App started. Online displays: %s", list_all_online_displays())
        log.info("SkyLight=%s CoreDisplay=%s", _sls is not None, _cd is not None)
        refresh_ui()
        NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "screensDidChange:", NSApplicationDidChangeScreenParametersNotification, None
        )
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            5.0, self, "pollScreens:", None, True
        )

    def applicationWillTerminate_(self, notification):
        for did, is_dis in list(disabled_displays.items()):
            if is_dis:
                log.info("[QUIT] Re-enabling display %d before exit", did)
                _sls_set_display_enabled(did, True)

    def screensDidChange_(self, notification):
        log.info("[SCREENS] Display config changed — refreshing UI")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, self, "delayedRefresh:", None, False
        )

    def delayedRefresh_(self, timer):
        refresh_ui()

    def pollScreens_(self, timer):
        refresh_ui()

    def toggleDisplay_(self, sender):
        display_id = int(sender.tag())
        new_state = sender.state()
        log.info("[TOGGLE] display=%d → %s", display_id,
                 "enable" if new_state == NSControlStateValueOn else "disable")
        if new_state == NSControlStateValueOff:
            self._disable_display(display_id)
        else:
            self._enable_display(display_id)

    @objc.python_method
    def _disable_display(self, display_id: int):
        active_ids = [s.deviceDescription().get("NSScreenNumber", 0) for s in NSScreen.screens()]
        if display_id not in active_ids:
            log.warning("[DISABLE] Display %d not in active config", display_id)
            refresh_ui()
            return
        ok = _sls_set_display_enabled(display_id, False)
        if ok:
            disabled_displays[display_id] = True
            log.info("[DISABLE] ✓ display %d removed from active config", display_id)
        else:
            log.error("[DISABLE] FAILED for display %d", display_id)
        refresh_ui()
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "delayedRefresh:", None, False
        )

    @objc.python_method
    def _enable_display(self, display_id: int):
        ok = _sls_set_display_enabled(display_id, True)
        if ok:
            disabled_displays[display_id] = False
            log.info("[ENABLE] ✓ display %d restored to active config", display_id)
        else:
            log.error("[ENABLE] FAILED for display %d", display_id)
        refresh_ui()
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "delayedRefresh:", None, False
        )

    def adjustBrightness_(self, sender):
        display_id = int(sender.tag())
        value = sender.doubleValue()
        set_display_brightness(display_id, value)
        log.debug("[BRIGHTNESS] display=%d → %.0f%%", display_id, value * 100)

    def changeResolution_(self, sender):
        display_id = int(sender.tag())
        idx = sender.indexOfSelectedItem()
        modes = get_display_modes(display_id)
        if 0 <= idx < len(modes):
            w, h, r = modes[idx]
            log.info("[RES] Changing display %d → %dx%d", display_id, w, h)
            ok = set_display_resolution(display_id, w, h, r)
            if ok:
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                    0.5, self, "delayedRefresh:", None, False
                )

    def openDDCConfig_(self, sender):
        log.info("[DDC] Opening System Display Preferences")
        subprocess.Popen(["open", "x-apple.systempreferences:com.apple.preference.displays"])


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    log.info("DisableScreen launching...")
    app = NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    app.run()
