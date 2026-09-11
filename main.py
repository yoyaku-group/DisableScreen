#!/usr/bin/env python3
"""DisableScreen — Multi-display management menu bar app (window-based popup)."""

import AppKit
import objc
import ctypes
import json
import logging
import subprocess
import time
from pathlib import Path
from Quartz import (
    CGDisplayIsBuiltin, CGGetOnlineDisplayList,
    CGDisplayCopyAllDisplayModes, CGDisplaySetDisplayMode,
    CGDisplayCopyDisplayMode, CGDisplayModeGetWidth,
    CGDisplayModeGetHeight, CGDisplayModeGetRefreshRate,
)
from AppKit import (
    NSApp, NSApplication, NSStatusBar, NSScreen, NSColor, NSImage, NSFont,
    NSTextField, NSImageView, NSView, NSTimer, NSSlider, NSButton, NSPopUpButton,
    NSPanel, NSControlStateValueOn, NSControlStateValueOff,
    NSApplicationActivationPolicyAccessory, NSSquareStatusItemLength,
    NSImageScaleProportionallyDown, NSApplicationDidChangeScreenParametersNotification,
    NSTextAlignmentRight, NSBackingStoreBuffered, NSWindowStyleMaskBorderless,
    NSEvent, NSVisualEffectView, NSVisualEffectBlendingModeBehindWindow,
    NSVisualEffectStateActive, NSMenu, NSMenuItem,
    NSWindow, NSBorderlessWindowMask, NSScreenSaverWindowLevel,
    NSWindowCollectionBehaviorCanJoinAllSpaces, NSWindowCollectionBehaviorStationary,
    NSWindowCollectionBehaviorFullScreenAuxiliary, NSWindowCollectionBehaviorIgnoresCycle,
)
from Foundation import NSMakeRect, NSNotificationCenter, NSMakePoint, NSBundle

LOG_PATH = Path.home() / "DisableScreen" / "disablescreen.log"


# Localization — resolves strings from Contents/Resources/<lang>.lproj/Localizable.strings
# based on NSLocale.preferredLanguages. Falls back to the key itself if missing.
def _(key: str, fallback: str = None) -> str:
    try:
        s = NSBundle.mainBundle().localizedStringForKey_value_table_(
            key, fallback or key, None
        )
        return str(s)
    except Exception:
        return fallback or key

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler()],
)
log = logging.getLogger("DisableScreen")

PANEL_W  = 280
CORNER_R = 12.0

disabled_displays = {}
status_item   = None
popup_panel   = None
event_monitor = None

# CoreGraphics
_cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
_cg.CGBeginDisplayConfiguration.restype  = ctypes.c_int32
_cg.CGBeginDisplayConfiguration.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
_cg.CGCompleteDisplayConfiguration.restype  = ctypes.c_int32
_cg.CGCompleteDisplayConfiguration.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
_cg.CGCancelDisplayConfiguration.restype  = ctypes.c_int32
_cg.CGCancelDisplayConfiguration.argtypes = [ctypes.c_void_p]

# SkyLight
try:
    _sls = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
    _sls.SLSConfigureDisplayEnabled.restype  = ctypes.c_int32
    _sls.SLSConfigureDisplayEnabled.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_bool]
    log.info("SkyLight OK")
except Exception as e:
    _sls = None
    log.error("SkyLight FAILED: %s", e)

# CoreDisplay — load in two separate try/except so partial success is OK
_cd = _ds_get = _ds_set = None
try:
    _cd = ctypes.CDLL('/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay')
    _cd.CoreDisplay_Display_GetUserBrightness.restype  = ctypes.c_double
    _cd.CoreDisplay_Display_GetUserBrightness.argtypes = [ctypes.c_uint32]
    _cd.CoreDisplay_Display_SetUserBrightness.restype  = None
    _cd.CoreDisplay_Display_SetUserBrightness.argtypes = [ctypes.c_uint32, ctypes.c_double]
    log.info("CoreDisplay OK")
except Exception as e:
    log.error("CoreDisplay FAILED: %s", e)

try:
    if _cd:
        _g = _cd.DisplayServicesGetBrightness
        _g.restype  = ctypes.c_int32
        _g.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_float)]
        _s = _cd.DisplayServicesSetBrightness
        _s.restype  = ctypes.c_int32
        _s.argtypes = [ctypes.c_uint32, ctypes.c_float]
        _ds_get, _ds_set = _g, _s
        log.info("DisplayServices OK")
except Exception as e:
    log.info("DisplayServices not available (OK): %s", e)

# IOKit (DDC fallback for external monitors)
_iokit = _cf = None
try:
    _iokit = ctypes.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
    _cf    = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    _iokit.IOServiceMatching.restype  = ctypes.c_void_p
    _iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
    _iokit.IOServiceGetMatchingServices.restype  = ctypes.c_uint32
    _iokit.IOServiceGetMatchingServices.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    _iokit.IOIteratorNext.restype  = ctypes.c_uint32
    _iokit.IOIteratorNext.argtypes = [ctypes.c_uint32]
    _iokit.IOObjectRelease.restype  = ctypes.c_uint32
    _iokit.IOObjectRelease.argtypes = [ctypes.c_uint32]
    _iokit.IODisplaySetFloatParameter.restype  = ctypes.c_uint32
    _iokit.IODisplaySetFloatParameter.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_float]
    _iokit.IODisplayGetFloatParameter.restype  = ctypes.c_uint32
    _iokit.IODisplayGetFloatParameter.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_float)]
    _cf.CFStringCreateWithCString.restype  = ctypes.c_void_p
    _cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    _cf.CFRelease.restype  = None
    _cf.CFRelease.argtypes = [ctypes.c_void_p]
    log.info("IOKit OK")
except Exception as e:
    log.warning("IOKit FAILED (no DDC): %s", e)


def _iokit_brightness(value=None):
    if not _iokit or not _cf:
        return -1.0 if value is None else False
    try:
        key = _cf.CFStringCreateWithCString(None, b"brightness", 0)
        it  = ctypes.c_uint32(0)
        if _iokit.IOServiceGetMatchingServices(0, _iokit.IOServiceMatching(b"IODisplayConnect"), ctypes.byref(it)) != 0:
            _cf.CFRelease(key)
            return -1.0 if value is None else False
        ok = False; rv = -1.0
        svc = _iokit.IOIteratorNext(it)
        while svc:
            if value is None:
                v = ctypes.c_float(0.0)
                if _iokit.IODisplayGetFloatParameter(svc, 0, key, ctypes.byref(v)) == 0:
                    rv = float(v.value)
            else:
                if _iokit.IODisplaySetFloatParameter(svc, 0, key, ctypes.c_float(value)) == 0:
                    ok = True
            _iokit.IOObjectRelease(svc)
            svc = _iokit.IOIteratorNext(it)
        _iokit.IOObjectRelease(it)
        _cf.CFRelease(key)
        return rv if value is None else ok
    except Exception as e:
        log.error("IOKit brightness: %s", e)
        return -1.0 if value is None else False


# ── Dim overlay windows ───────────────────────────────────────────────────────
# On Apple Silicon + USB-C portable monitors (e.g. ASUS MB16AH), both DDC writes
# and CGSetDisplayTransferByFormula are ignored by the display. The only way to
# actually dim visible output is a black, click-through NSWindow layered above
# everything at NSScreenSaverWindowLevel.
_dim_windows: dict = {}
_sw_brightness: dict = {}


def _screen_for_display(display_id: int):
    for screen in NSScreen.screens():
        if int(screen.deviceDescription().get("NSScreenNumber", 0)) == display_id:
            return screen
    return None


def _ensure_dim_window(display_id: int):
    screen = _screen_for_display(display_id)
    if screen is None:
        return None
    frame = screen.frame()
    win = _dim_windows.get(display_id)
    if win is None:
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_screen_(
            frame, NSBorderlessWindowMask, NSBackingStoreBuffered, False, screen,
        )
        win.setOpaque_(False)
        win.setHasShadow_(False)
        win.setIgnoresMouseEvents_(True)
        win.setLevel_(NSScreenSaverWindowLevel)
        win.setBackgroundColor_(NSColor.blackColor())
        win.setAlphaValue_(0.0)
        win.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorIgnoresCycle
        )
        win.orderFrontRegardless()
        _dim_windows[display_id] = win
        log.info("[DIM] created overlay for display %d", display_id)
    else:
        win.setFrame_display_(frame, True)
        win.orderFrontRegardless()
    return win


def _apply_dim(display_id: int, value: float) -> bool:
    value = max(0.08, min(1.0, value))  # floor so the screen never blacks out
    win = _ensure_dim_window(display_id)
    if win is None:
        return False
    win.setAlphaValue_(1.0 - value)
    log.info("[DIM] display=%d brightness=%.2f", display_id, value)
    return True


def get_display_brightness(display_id: int) -> float:
    if CGDisplayIsBuiltin(display_id):
        if _ds_get:
            try:
                v = ctypes.c_float(0.0)
                if _ds_get(ctypes.c_uint32(display_id), ctypes.byref(v)) == 0 and 0.0 <= v.value <= 1.0:
                    return float(v.value)
            except Exception:
                pass
        if _cd:
            try:
                v = _cd.CoreDisplay_Display_GetUserBrightness(ctypes.c_uint32(display_id))
                if 0.0 <= v <= 1.0:
                    return float(v)
            except Exception:
                pass
        return -1.0
    # External → overlay state (IOKit kept as best-effort write fallback)
    return _sw_brightness.get(display_id, 1.0)


def set_display_brightness(display_id: int, value: float):
    value = max(0.0, min(1.0, value))
    if CGDisplayIsBuiltin(display_id):
        if _ds_set:
            try:
                if _ds_set(ctypes.c_uint32(display_id), ctypes.c_float(value)) == 0:
                    return
            except Exception:
                pass
        if _cd:
            try:
                _cd.CoreDisplay_Display_SetUserBrightness(ctypes.c_uint32(display_id), ctypes.c_double(value))
                return
            except Exception:
                pass
        return
    # External → overlay dim (only reliable path on Apple Silicon for USB-C portables)
    if _apply_dim(display_id, value):
        _sw_brightness[display_id] = value
    # Best-effort DDC via IOKit, no-op on MB16AH but may help other monitors
    _iokit_brightness(value)


def _sls_set_display_enabled(display_id: int, enabled: bool) -> bool:
    if not _sls:
        return False
    config = ctypes.c_void_p()
    if _cg.CGBeginDisplayConfiguration(ctypes.byref(config)) != 0:
        return False
    err = _sls.SLSConfigureDisplayEnabled(config, ctypes.c_uint32(display_id), ctypes.c_bool(enabled))
    if err != 0:
        _cg.CGCancelDisplayConfiguration(config)
        log.error("[SLS] failed: %d", err)
        return False
    if _cg.CGCompleteDisplayConfiguration(config, ctypes.c_uint32(0)) != 0:
        return False
    log.info("[SLS] display %d enabled=%s OK", display_id, enabled)
    return True


def get_current_resolution(display_id: int) -> str:
    try:
        m = CGDisplayCopyDisplayMode(display_id)
        if m:
            return f"{int(CGDisplayModeGetWidth(m))}x{int(CGDisplayModeGetHeight(m))}"
    except Exception:
        pass
    return "-"


def get_display_modes(display_id: int):
    try:
        modes = CGDisplayCopyAllDisplayModes(display_id, None)
        if not modes:
            return []
        best = {}
        for m in modes:
            w, h, r = int(CGDisplayModeGetWidth(m)), int(CGDisplayModeGetHeight(m)), CGDisplayModeGetRefreshRate(m)
            if w > 0 and h > 0 and ((w, h) not in best or r > best[(w, h)]):
                best[(w, h)] = r
        return sorted([(w, h, r) for (w, h), r in best.items()], key=lambda x: (-x[0], -x[1]))[:20]
    except Exception as e:
        log.error("get_display_modes: %s", e)
        return []


def set_display_resolution(display_id: int, width: int, height: int) -> bool:
    try:
        modes = CGDisplayCopyAllDisplayModes(display_id, None)
        best_mode, best_r = None, -1.0
        for m in modes:
            w, h, r = int(CGDisplayModeGetWidth(m)), int(CGDisplayModeGetHeight(m)), CGDisplayModeGetRefreshRate(m)
            if w == width and h == height and r >= best_r:
                best_mode, best_r = m, r
        if best_mode is not None:
            config = ctypes.c_void_p()
            _cg.CGBeginDisplayConfiguration(ctypes.byref(config))
            CGDisplaySetDisplayMode(display_id, best_mode, None)
            _cg.CGCompleteDisplayConfiguration(config, ctypes.c_uint32(0))
            return True
    except Exception as e:
        log.error("set_display_resolution: %s", e)
    return False


def list_all_online_displays():
    _err, displays, _count = CGGetOnlineDisplayList(16, None, None)
    return list(displays)


def get_display_name(display_id: int) -> str:
    for screen in NSScreen.screens():
        if screen.deviceDescription().get("NSScreenNumber", 0) == display_id:
            return screen.localizedName() or f"Display {display_id}"
    return f"Display {display_id}"


def _sf(name):
    return NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)


def _make_sep(w):
    v = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, w, 1))
    v.setWantsLayer_(True)
    v.layer().setBackgroundColor_(NSColor.separatorColor().CGColor())
    return v


def _make_display_card(display_id, delegate, w):
    builtin = bool(CGDisplayIsBuiltin(display_id))
    is_dis  = disabled_displays.get(display_id, False)
    name    = "Écran intégré" if builtin else get_display_name(display_id)
    bri, res, modes = -1.0, "-", []
    if not is_dis:
        bri   = get_display_brightness(display_id)
        res   = get_current_resolution(display_id)
        modes = get_display_modes(display_id)
    if not builtin and bri < 0.0:
        bri = _sw_brightness.get(display_id, 1.0)
    has_bri = bri >= 0.0

    H_HDR = 46; H_DDC = 36; H_BRI = 34; H_RES = 34
    h = H_HDR
    if not is_dis:
        if not builtin: h += H_DDC
        if has_bri: h += H_BRI
        h += H_RES

    card = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, w, h))
    y = h - H_HDR

    ico = NSImageView.alloc().initWithFrame_(NSMakeRect(14, y + 14, 18, 18))
    ico.setImage_(_sf("laptopcomputer" if builtin else "display"))
    ico.setImageScaling_(NSImageScaleProportionallyDown)
    if is_dis: ico.setAlphaValue_(0.35)
    card.addSubview_(ico)

    nf = NSTextField.labelWithString_(name)
    nf.setFrame_(NSMakeRect(40, y + 17, w - 100, 15))
    nf.setFont_(NSFont.boldSystemFontOfSize_(13.0))
    if is_dis: nf.setTextColor_(NSColor.tertiaryLabelColor())
    card.addSubview_(nf)

    if not is_dis and res != "-":
        sf = NSTextField.labelWithString_(res)
        sf.setFrame_(NSMakeRect(40, y + 4, 120, 11))
        sf.setFont_(NSFont.systemFontOfSize_(10.0))
        sf.setTextColor_(NSColor.secondaryLabelColor())
        card.addSubview_(sf)

    active_count = sum(1 for d in list_all_online_displays() if not disabled_displays.get(d, False))
    sw = AppKit.NSSwitch.alloc().init()
    sw.setState_(NSControlStateValueOff if is_dis else NSControlStateValueOn)
    sw.setTag_(display_id)
    sw.setTarget_(delegate)
    sw.setAction_("toggleDisplay:")
    if not is_dis and active_count <= 1: sw.setEnabled_(False)
    sw.setFrame_(NSMakeRect(w - 54, y + 12, 44, 22))
    card.addSubview_(sw)

    if is_dis:
        return card, h

    if not builtin:
        y -= H_DDC
        btn = NSButton.alloc().initWithFrame_(NSMakeRect(14, y + 6, w - 28, 24))
        btn.setTitle_(_("button.configure_ddc", "Click to configure DDC..."))
        btn.setBezelStyle_(1)
        btn.setFont_(NSFont.systemFontOfSize_(11.0))
        btn.setTag_(display_id)
        btn.setTarget_(delegate)
        btn.setAction_("openDDCConfig:")
        try: btn.setContentTintColor_(NSColor.systemBlueColor())
        except Exception: pass
        card.addSubview_(btn)

    if has_bri:
        y -= H_BRI
        sun = NSImageView.alloc().initWithFrame_(NSMakeRect(14, y + 10, 14, 14))
        sun.setImage_(_sf("sun.min"))
        sun.setImageScaling_(NSImageScaleProportionallyDown)
        card.addSubview_(sun)

        pct = NSTextField.labelWithString_(f"{int(bri * 100)}%")
        pct.setFrame_(NSMakeRect(w - 44, y + 11, 30, 13))
        pct.setFont_(NSFont.systemFontOfSize_(11.0))
        pct.setAlignment_(NSTextAlignmentRight)
        pct.setTag_(display_id + 100000)
        card.addSubview_(pct)

        sl = NSSlider.alloc().initWithFrame_(NSMakeRect(34, y + 6, w - 84, 22))
        sl.setMinValue_(0.0)
        sl.setMaxValue_(1.0)
        sl.setDoubleValue_(bri)
        sl.setTag_(display_id)
        sl.setTarget_(delegate)
        sl.setAction_("adjustBrightness:")
        sl.setContinuous_(True)
        card.addSubview_(sl)

    y -= H_RES
    ri = NSImageView.alloc().initWithFrame_(NSMakeRect(14, y + 10, 14, 14))
    ri.setImage_(_sf("aspectratio"))
    ri.setImageScaling_(NSImageScaleProportionallyDown)
    card.addSubview_(ri)

    if modes:
        pu = NSPopUpButton.alloc().initWithFrame_pullsDown_(NSMakeRect(34, y + 6, w - 48, 22), False)
        pu.setFont_(NSFont.systemFontOfSize_(11.5))
        cp = res.split("x") if "x" in res else ["0", "0"]
        cw, ch = int(cp[0]) if len(cp) >= 2 else 0, int(cp[1]) if len(cp) >= 2 else 0
        sel = 0
        for i, (mw, mh, mr) in enumerate(modes):
            pu.addItemWithTitle_(f"{mw}x{mh}" + (f"  @{int(mr)}Hz" if mr > 0 else ""))
            if mw == cw and mh == ch: sel = i
        pu.selectItemAtIndex_(sel)
        pu.setTag_(display_id)
        pu.setTarget_(delegate)
        pu.setAction_("changeResolution:")
        card.addSubview_(pu)
    else:
        rl = NSTextField.labelWithString_(res)
        rl.setFrame_(NSMakeRect(34, y + 11, w - 48, 14))
        rl.setFont_(NSFont.systemFontOfSize_(12.0))
        card.addSubview_(rl)

    return card, h


def _build_content(delegate):
    all_disp = sorted(list_all_online_displays(), key=lambda d: (1 if CGDisplayIsBuiltin(d) else 0, d))
    sections = [_make_display_card(d, delegate, PANEL_W) for d in all_disp]

    H_PAD = 8; H_SEP = 1; H_QUIT = 36; H_LID = 36
    total_h = H_PAD
    for _view, h in sections:
        total_h += h
    total_h += (len(sections) - 1) * (H_SEP + 4)
    total_h += H_SEP + H_QUIT + H_SEP + H_LID + H_PAD

    root = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, PANEL_W, total_h))
    y = H_PAD

    q = NSButton.alloc().initWithFrame_(NSMakeRect(14, y + 6, PANEL_W - 28, 24))
    q.setTitle_(_("menu.quit", "Quit"))
    q.setBezelStyle_(1)
    q.setFont_(NSFont.systemFontOfSize_(13.0))
    q.setTarget_(NSApp)
    q.setAction_("terminate:")
    root.addSubview_(q)
    y += H_QUIT

    sv0 = _make_sep(PANEL_W)
    sv0.setFrame_(NSMakeRect(0, y, PANEL_W, H_SEP))
    root.addSubview_(sv0)
    y += H_SEP

    lid_on = _lid_stay_awake_state()
    lid_lbl = NSTextField.labelWithString_(_("menu.keep_awake_lid_closed", "Keep awake with lid closed"))
    lid_lbl.setFrame_(NSMakeRect(14, y + 11, PANEL_W - 80, 14))
    lid_lbl.setFont_(NSFont.systemFontOfSize_(12.0))
    root.addSubview_(lid_lbl)

    lid_sw = AppKit.NSSwitch.alloc().init()
    lid_sw.setState_(NSControlStateValueOn if lid_on else NSControlStateValueOff)
    lid_sw.setTarget_(delegate)
    lid_sw.setAction_("toggleLidStayAwake:")
    lid_sw.setFrame_(NSMakeRect(PANEL_W - 54, y + 7, 44, 22))
    root.addSubview_(lid_sw)
    y += H_LID

    sv = _make_sep(PANEL_W)
    sv.setFrame_(NSMakeRect(0, y, PANEL_W, H_SEP))
    root.addSubview_(sv)
    y += H_SEP + 4

    for i, (card, h) in enumerate(reversed(sections)):
        card.setFrame_(NSMakeRect(0, y, PANEL_W, h))
        root.addSubview_(card)
        y += h
        if i < len(sections) - 1:
            sv2 = _make_sep(PANEL_W)
            sv2.setFrame_(NSMakeRect(0, y, PANEL_W, H_SEP))
            root.addSubview_(sv2)
            y += H_SEP + 4

    fx = NSVisualEffectView.alloc().initWithFrame_(NSMakeRect(0, 0, PANEL_W, total_h))
    try:
        fx.setMaterial_(AppKit.NSVisualEffectMaterialPopover)
    except Exception:
        fx.setMaterial_(3)
    fx.setBlendingMode_(NSVisualEffectBlendingModeBehindWindow)
    fx.setState_(NSVisualEffectStateActive)
    fx.setWantsLayer_(True)
    fx.layer().setCornerRadius_(CORNER_R)
    fx.layer().setMasksToBounds_(True)
    fx.addSubview_(root)
    return fx, total_h


class DisplayPanel(NSPanel):
    @classmethod
    def create(cls):
        p = cls.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, PANEL_W, 100),
            NSWindowStyleMaskBorderless | (1 << 7),
            NSBackingStoreBuffered, False,
        )
        p.setLevel_(AppKit.NSPopUpMenuWindowLevel)
        p.setCollectionBehavior_(
            AppKit.NSWindowCollectionBehaviorCanJoinAllSpaces |
            AppKit.NSWindowCollectionBehaviorTransient
        )
        p.setHasShadow_(True)
        p.setOpaque_(False)
        p.setBackgroundColor_(NSColor.clearColor())
        return p

    def canBecomeKeyWindow(self):
        return True

    def resignKeyWindow(self):
        super().resignKeyWindow()
        AppDelegate.shared.hidePanel()

    def keyDown_(self, event):
        if event.keyCode() == 53:
            AppDelegate.shared.hidePanel()
        else:
            super().keyDown_(event)


def _show_popup(delegate):
    global popup_panel, event_monitor
    if popup_panel is None:
        popup_panel = DisplayPanel.create()

    content, panel_h = _build_content(delegate)
    popup_panel.setContentView_(content)
    popup_panel.setFrame_display_(NSMakeRect(0, 0, PANEL_W, panel_h), False)

    btn = status_item.button()
    btn_win = btn.window()
    if btn_win:
        br = btn_win.convertRectToScreen_(btn.frame())
        # Anchor to the screen that actually contains the status item (NOT
        # mainScreen — that's the key-window screen, can differ on multi-display).
        anchor_screen = btn_win.screen() or NSScreen.mainScreen()
        sf = anchor_screen.frame()
        px = br.origin.x + br.size.width / 2 - PANEL_W / 2
        px = max(sf.origin.x + 8, min(px, sf.origin.x + sf.size.width - PANEL_W - 8))
        # Vertical clamp: a Bartender-collapsed status item reports an
        # off-screen button frame (observed y=1120 on a 1117pt screen),
        # which used to open the panel below the visible area.
        y_top = br.origin.y
        y_top = min(y_top, sf.origin.y + sf.size.height - 2.0)
        y_top = max(y_top, sf.origin.y + panel_h + 2.0)
        popup_panel.setFrameTopLeftPoint_(NSMakePoint(px, y_top))
    else:
        # No resolvable status-item window: anchor top-right of main screen.
        sf = NSScreen.mainScreen().frame()
        px = sf.origin.x + sf.size.width - PANEL_W - 12
        popup_panel.setFrameTopLeftPoint_(
            NSMakePoint(px, sf.origin.y + sf.size.height - 40.0))

    popup_panel.makeKeyAndOrderFront_(None)

    def _dismiss(evt):
        if evt.window() != popup_panel:
            AppDelegate.shared.hidePanel()

    if event_monitor:
        NSEvent.removeMonitor_(event_monitor)
    event_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(1 | 2, _dismiss)


def _hide_popup():
    global event_monitor
    if popup_panel:
        popup_panel.orderOut_(None)
    if event_monitor:
        NSEvent.removeMonitor_(event_monitor)
        event_monitor = None


# Login item management: the compiled launcher binary (this app's main executable)
# owns SMAppService calls, because NSBundle.mainBundle() resolves to DisableScreen.app
# only when called from the bundled binary — not from the Python interpreter.
def _launcher_path() -> str:
    """Path to the DisableScreen launcher executable (the binary that launched
    this Python interpreter). Resolved at runtime via NSBundle — falls back to
    the standard install location when running outside a bundle (e.g. dev)."""
    b = NSBundle.mainBundle()
    if b is not None:
        p = b.executablePath()
        if p:
            return str(p)
    return "/Applications/DisableScreen.app/Contents/MacOS/DisableScreen"


def _login_item_status_str() -> str:
    try:
        out = subprocess.check_output([_launcher_path(), "--status"], text=True, timeout=5).strip()
        return out
    except Exception as e:
        log.error("login status: %s", e)
        return "unknown"


_SETTINGS = Path.home() / "DisableScreen" / "settings.json"


def _read_wants_login_item():
    """True/False if the user ever toggled the login item, None otherwise.
    Stored as a plain file: this PyObjC process is exec'd from the Python
    framework, so NSUserDefaults does not reliably resolve the app domain."""
    try:
        v = json.loads(_SETTINGS.read_text()).get("wants_login_item")
        return v if isinstance(v, bool) else None
    except Exception:
        return None


def _write_wants_login_item(value: bool):
    try:
        _SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        data = {}
        if _SETTINGS.exists():
            data = json.loads(_SETTINGS.read_text())
        data["wants_login_item"] = value
        _SETTINGS.write_text(json.dumps(data, indent=2))
    except Exception as e:
        log.error("settings write: %s", e)


def _is_login_item() -> bool:
    return _login_item_status_str() == "enabled"


def _set_login_item(enabled: bool):
    arg = "--register" if enabled else "--unregister"
    try:
        r = subprocess.run([_launcher_path(), arg], capture_output=True, text=True, timeout=10)
        log.info("login item %s: rc=%d stderr=%s new_status=%s",
                 arg, r.returncode, r.stderr.strip(), _login_item_status_str())
        if r.returncode != 0 and enabled and _login_item_status_str() == "requiresApproval":
            subprocess.Popen(["open", "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"])
    except Exception as e:
        log.error("login item toggle: %s", e)


# ── Lid-close stay-awake (pmset disablesleep) ─────────────────────────────────
def _lid_stay_awake_state() -> bool:
    """True if pmset SleepDisabled is set (system stays on with lid closed)."""
    try:
        out = subprocess.check_output(["pmset", "-g"], text=True, timeout=3)
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("SleepDisabled"):
                return s.split()[-1] == "1"
    except Exception as e:
        log.error("lid stay-awake state: %s", e)
    return False


def _set_lid_stay_awake(enabled: bool):
    val = "1" if enabled else "0"
    # Whitelisted in /etc/sudoers.d/disablescreen-pmset → no password prompt.
    try:
        r = subprocess.run(
            ["sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", val],
            capture_output=True, text=True, timeout=10,
        )
        log.info("lid stay-awake → %s: rc=%d stderr=%s",
                 enabled, r.returncode, r.stderr.strip())
        if r.returncode != 0:
            log.error("sudo NOPASSWD failed — sudoers rule missing? rc=%d", r.returncode)
    except Exception as e:
        log.error("lid stay-awake toggle: %s", e)


def _build_right_click_menu(delegate):
    menu = NSMenu.alloc().init()

    login_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        _("menu.open_at_login", "Open at Login"), "toggleLoginItem:", ""
    )
    login_item.setTarget_(delegate)
    if _is_login_item():
        login_item.setState_(NSControlStateValueOn)
    menu.addItem_(login_item)

    lid_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        _("menu.keep_awake_lid_closed", "Keep awake with lid closed"), "toggleLidStayAwake:", ""
    )
    lid_item.setTarget_(delegate)
    if _lid_stay_awake_state():
        lid_item.setState_(NSControlStateValueOn)
    menu.addItem_(lid_item)

    menu.addItem_(NSMenuItem.separatorItem())

    quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(_("menu.quit", "Quit"), "terminate:", "q")
    menu.addItem_(quit_item)

    return menu


def ensure_status_item(delegate):
    global status_item
    if status_item is None or status_item.button() is None:
        status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSSquareStatusItemLength)
        status_item.button().setTarget_(delegate)
        status_item.button().setAction_("togglePanel:")
        status_item.button().sendActionOn_(AppKit.NSEventMaskLeftMouseUp | AppKit.NSEventMaskRightMouseUp)
    any_dis = any(disabled_displays.values())
    status_item.button().setImage_(_sf("display.slash" if any_dis else "display"))


class AppDelegate(AppKit.NSObject):
    shared = None
    _panel_visible = False
    _panel_last_close = 0.0

    def applicationDidFinishLaunching_(self, notification):
        AppDelegate.shared = self
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        ensure_status_item(self)
        # Self-heal the login item: a rebuild changes the ad-hoc signature and
        # silently drops the SMAppService registration. Restore the user's
        # last known choice without asking again (trap found 2026-08-27).
        _wants_li = _read_wants_login_item()
        if _wants_li is None:
            _write_wants_login_item(_is_login_item())
        elif _wants_li and not _is_login_item():
            _set_login_item(True)
            log.info("[SELF-HEAL] login item re-registered (signature changed by rebuild)")
        log.info("Started. Displays: %s | SkyLight=%s CoreDisplay=%s | LoginItem=%s",
                 list_all_online_displays(), _sls is not None, _cd is not None, _login_item_status_str())
        NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "screensDidChange:", NSApplicationDidChangeScreenParametersNotification, None
        )
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            5.0, self, "pollScreens:", None, True
        )

    def applicationShouldHandleReopen_hasVisibleWindows_(self, sender, has_visible):
        # Finder double-click / `open -a` on the already-running app must
        # still show the panel even when the menu-bar icon is collapsed
        # (Bartender). Fixes "app won't open" reports.
        self.togglePanel_(None)
        return True

    def applicationWillTerminate_(self, notification):
        for did, is_dis in list(disabled_displays.items()):
            if is_dis:
                log.info("[QUIT] Re-enabling display %d", did)
                _sls_set_display_enabled(did, True)

    def screensDidChange_(self, notification):
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.3, self, "delayedRefresh:", None, False
        )

    def delayedRefresh_(self, timer):
        ensure_status_item(self)
        if self._panel_visible:
            _show_popup(self)

    def pollScreens_(self, timer):
        ensure_status_item(self)

    def togglePanel_(self, sender):
        event = NSApp.currentEvent()
        if event and event.type() == AppKit.NSEventTypeRightMouseUp:
            menu = _build_right_click_menu(self)
            status_item.popUpStatusItemMenu_(menu)
            return
        # Guard against resignKeyWindow → hidePanel → togglePanel_ race:
        # if the panel was just closed (< 200ms ago), don't reopen it
        just_closed = (time.time() - self._panel_last_close) < 0.20
        if self._panel_visible or just_closed:
            self.hidePanel()
        else:
            self.showPanel()

    def toggleLoginItem_(self, sender):
        currently = _is_login_item()
        _set_login_item(not currently)
        _write_wants_login_item(not currently)
        log.info("Login item: %s → %s", currently, not currently)

    def toggleLidStayAwake_(self, sender):
        currently = _lid_stay_awake_state()
        _set_lid_stay_awake(not currently)
        log.info("Lid stay-awake: %s → %s", currently, not currently)

    @objc.python_method
    def showPanel(self):
        self._panel_visible = True
        try:
            _show_popup(self)
        except Exception:
            log.exception("[POPUP] _show_popup crashed")
            self._panel_visible = False

    @objc.python_method
    def hidePanel(self):
        self._panel_visible = False
        self._panel_last_close = time.time()
        _hide_popup()

    def toggleDisplay_(self, sender):
        display_id = int(sender.tag())
        if sender.state() == NSControlStateValueOff:
            active = [s.deviceDescription().get("NSScreenNumber", 0) for s in NSScreen.screens()]
            if display_id not in active:
                log.warning("[DISABLE] display %d not active", display_id)
                _show_popup(self)
                return
            if _sls_set_display_enabled(display_id, False):
                disabled_displays[display_id] = True
        else:
            if _sls_set_display_enabled(display_id, True):
                disabled_displays[display_id] = False
        ensure_status_item(self)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "delayedRefresh:", None, False
        )

    def adjustBrightness_(self, sender):
        display_id = int(sender.tag())
        value = sender.doubleValue()
        set_display_brightness(display_id, value)
        if popup_panel:
            lbl = popup_panel.contentView().viewWithTag_(display_id + 100000)
            if lbl:
                lbl.setStringValue_(f"{int(value * 100)}%")

    def changeResolution_(self, sender):
        display_id = int(sender.tag())
        idx = sender.indexOfSelectedItem()
        modes = get_display_modes(display_id)
        if 0 <= idx < len(modes):
            w, h, _mode = modes[idx]
            set_display_resolution(display_id, w, h)
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.5, self, "delayedRefresh:", None, False
            )

    def openDDCConfig_(self, sender):
        subprocess.Popen(["open", "x-apple.systempreferences:com.apple.preference.displays"])


if __name__ == "__main__":
    log.info("DisableScreen launching...")
    app = NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    app.run()
