#!/usr/bin/env python3
"""DisableScreen — Multi-display management menu bar app (window-based popup)."""

import AppKit
import objc
import ctypes
import json
import logging
import subprocess
import threading
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

# A01: create the log directory BEFORE building the FileHandler. On a fresh
# account ~/DisableScreen does not exist yet, and FileHandler(LOG_PATH) raised
# before the UI could even start. If the directory cannot be created, fall back
# to stderr-only logging instead of crashing.
_log_handlers = [logging.StreamHandler()]
try:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    _log_handlers.insert(0, logging.FileHandler(LOG_PATH))
except OSError as _e:
    print(f"[DisableScreen] log dir unavailable ({_e}); stderr only", flush=True)


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
    handlers=_log_handlers,
)
log = logging.getLogger("DisableScreen")

PANEL_W  = 280
CORNER_R = 12.0

disabled_displays = {}
status_item   = None
popup_panel   = None

# A09: pmset -g and the login-item --status subprocess used to run synchronously
# on the UI thread while building the panel (multi-second timeouts). They now run
# in a background thread that fills this cache; the UI reads the cache and shows
# "…" until it is ready, then rebuilds. Values: lid ∈ {True,False,None}, login is
# a status string; "ready" flips True after the first successful refresh.
_status_cache = {"lid": None, "login": "…", "ready": False}
_status_lock  = threading.Lock()
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
    # A02: the brightness WRITE symbol (IODisplaySetFloatParameter) is deliberately
    # NOT declared — this build has no per-monitor DDC write path. Read-only only.
    _iokit.IODisplayGetFloatParameter.restype  = ctypes.c_uint32
    _iokit.IODisplayGetFloatParameter.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_float)]
    _cf.CFStringCreateWithCString.restype  = ctypes.c_void_p
    _cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    _cf.CFRelease.restype  = None
    _cf.CFRelease.argtypes = [ctypes.c_void_p]
    log.info("IOKit OK")
except Exception as e:
    log.warning("IOKit FAILED (no DDC): %s", e)


# A02: this used to WRITE brightness to EVERY IODisplayConnect service — a
# command meant for one monitor was broadcast to all of them, and there is no
# reliable per-monitor DDC transport proven on this hardware. The write path is
# removed. What remains is a READ-ONLY diagnostic (best-effort, first service),
# never wired into the per-display brightness action. External brightness is
# software dimming only (see set_display_brightness / _apply_dim).
def _iokit_brightness_readonly() -> float:
    """Best-effort diagnostic read of the first IODisplayConnect brightness.
    Returns -1.0 when unavailable. NEVER writes, NEVER broadcasts."""
    if not _iokit or not _cf:
        return -1.0
    try:
        key = _cf.CFStringCreateWithCString(None, b"brightness", 0)
        it  = ctypes.c_uint32(0)
        if _iokit.IOServiceGetMatchingServices(0, _iokit.IOServiceMatching(b"IODisplayConnect"), ctypes.byref(it)) != 0:
            _cf.CFRelease(key)
            return -1.0
        rv = -1.0
        svc = _iokit.IOIteratorNext(it)
        while svc:
            if rv < 0.0:
                v = ctypes.c_float(0.0)
                if _iokit.IODisplayGetFloatParameter(svc, 0, key, ctypes.byref(v)) == 0:
                    rv = float(v.value)
            _iokit.IOObjectRelease(svc)
            svc = _iokit.IOIteratorNext(it)
        _iokit.IOObjectRelease(it)
        _cf.CFRelease(key)
        return rv
    except Exception as e:
        log.error("IOKit brightness read: %s", e)
        return -1.0


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


DIM_FLOOR = 0.08  # overlay never fully blacks the screen out


def _apply_dim(display_id: int, value: float) -> float:
    """Apply software dimming. Returns the brightness ACTUALLY applied (>= floor),
    or -1.0 if the overlay could not be created. A07: the caller must cache the
    RETURNED value, not the requested one, so UI state matches what pixels show."""
    applied = max(DIM_FLOOR, min(1.0, value))
    win = _ensure_dim_window(display_id)
    if win is None:
        return -1.0
    win.setAlphaValue_(1.0 - applied)
    log.info("[DIM] display=%d applied=%.2f (requested=%.2f)", display_id, applied, value)
    return applied


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
    # External → software overlay dim only. A02: no IOKit/DDC broadcast write.
    # A07: cache the value ACTUALLY applied (post-floor), not the request.
    applied = _apply_dim(display_id, value)
    if applied >= 0.0:
        _sw_brightness[display_id] = applied


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


def set_display_resolution(display_id: int, width: int, height: int) -> dict:
    """A05: return a typed result — NEVER True on failure.

    CGDisplaySetDisplayMode is itself an atomic, immediate configuration call; the
    old code wrapped it in a decorative Begin/Complete transaction that it never
    fed the mode into, and ignored all three return codes. We call it directly,
    check its CGError, then read the mode back to confirm the observable outcome.

    Returns {ok, native_rc, readback_ok, error?}. ok is True only when the native
    call succeeded AND the read-back mode matches the request.
    """
    result = {"ok": False, "native_rc": None, "readback_ok": False}
    try:
        modes = CGDisplayCopyAllDisplayModes(display_id, None)
        best_mode, best_r = None, -1.0
        for m in modes or []:
            w, h, r = int(CGDisplayModeGetWidth(m)), int(CGDisplayModeGetHeight(m)), CGDisplayModeGetRefreshRate(m)
            if w == width and h == height and r >= best_r:
                best_mode, best_r = m, r
        if best_mode is None:
            result["error"] = "no matching mode"
            return result
        rc = CGDisplaySetDisplayMode(display_id, best_mode, None)
        result["native_rc"] = int(rc) if rc is not None else 0
        if result["native_rc"] != 0:
            result["error"] = f"CGDisplaySetDisplayMode rc={result['native_rc']}"
            return result
        # Readback: the observable outcome, not the API's word for it.
        result["readback_ok"] = get_current_resolution(display_id) == f"{width}x{height}"
        result["ok"] = result["readback_ok"]
    except Exception as e:
        log.error("set_display_resolution: %s", e)
        result["error"] = str(e)
    return result


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
        # A13: honest label — this opens macOS Display settings, it is NOT a
        # proven per-monitor DDC transport on this hardware.
        btn.setTitle_(_("button.open_display_settings", "Open macOS Display Settings…"))
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
        # A07: external displays dim via a software overlay floored at DIM_FLOOR;
        # expose that floor so the slider cannot promise a value it won't apply.
        sl.setMinValue_(0.0 if builtin else DIM_FLOOR)
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

    # A09/A10: read the cached tri-state, never probe pmset on the UI thread.
    lid_on = _cached_lid_state()
    ready = _status_ready()
    lid_text = _("menu.keep_awake_lid_closed", "Keep awake with lid closed")
    if not ready:
        lid_text += " (…)"           # cache not warm yet
    elif lid_on is None:
        lid_text += " (état inconnu)"  # A10: unknown ≠ off
    lid_lbl = NSTextField.labelWithString_(lid_text)
    lid_lbl.setFrame_(NSMakeRect(14, y + 11, PANEL_W - 80, 14))
    lid_lbl.setFont_(NSFont.systemFontOfSize_(12.0))
    root.addSubview_(lid_lbl)

    lid_sw = AppKit.NSSwitch.alloc().init()
    lid_sw.setState_(NSControlStateValueOn if lid_on is True else NSControlStateValueOff)
    if not ready or lid_on is None:
        lid_sw.setEnabled_(False)     # don't offer a toggle over an unknown state
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
BUNDLE_ID = "com.benjaminbelaga.DisableScreen"
_INSTALL_LAUNCHER = "/Applications/DisableScreen.app/Contents/MacOS/DisableScreen"


def _launcher_path():
    """Path to the DisableScreen launcher executable, or None if it cannot be
    identified. A06: NSBundle.executablePath() can be the Python interpreter
    (the app is a PyObjC exec), so we must verify the bundle IDENTITY, not just
    take whatever mainBundle reports. Returning the Python binary here would make
    login-item calls target the wrong executable."""
    b = NSBundle.mainBundle()
    if b is not None:
        try:
            ident = b.bundleIdentifier()
            p = b.executablePath()
        except Exception:
            ident = p = None
        if (ident == BUNDLE_ID and p and str(p).endswith("/Contents/MacOS/DisableScreen")
                and Path(str(p)).exists()):
            return str(p)
    # Fallback ONLY to the real installed launcher, and only if it exists.
    if Path(_INSTALL_LAUNCHER).exists():
        return _INSTALL_LAUNCHER
    return None


def _login_item_status_str() -> str:
    launcher = _launcher_path()
    if launcher is None:
        return "unavailable"  # A06: no verified launcher → don't shell out
    try:
        out = subprocess.check_output([launcher, "--status"], text=True, timeout=5).strip()
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
    launcher = _launcher_path()
    if launcher is None:
        log.warning("login item toggle skipped: no verified launcher (A06)")
        return
    arg = "--register" if enabled else "--unregister"
    try:
        r = subprocess.run([launcher, arg], capture_output=True, text=True, timeout=10)
        log.info("login item %s: rc=%d stderr=%s new_status=%s",
                 arg, r.returncode, r.stderr.strip(), _login_item_status_str())
        if r.returncode != 0 and enabled and _login_item_status_str() == "requiresApproval":
            subprocess.Popen(["open", "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"])
    except Exception as e:
        log.error("login item toggle: %s", e)


# ── Lid-close stay-awake (pmset disablesleep) ─────────────────────────────────
# A03 ownership model: `disablesleep` is a GLOBAL, ROOT, PERSISTENT system flag
# that survives our quit and even a reboot. Another tool (or the user) may own
# it. So we record what we found and only restore it if WE were the ones who
# flipped it, proven by a matching boot UUID and a read-back that still shows our
# value. We NEVER run an unconditional `disablesleep 0` on quit.
def _current_boot_uuid() -> str:
    try:
        return subprocess.check_output(
            ["sysctl", "-n", "kern.bootsessionuuid"], text=True, timeout=3
        ).strip()
    except Exception:
        return ""


def _lid_stay_awake_state():
    """Tri-state (A10): True / False if pmset reports SleepDisabled, or None when
    the state cannot be determined. None must NOT be shown as OFF."""
    try:
        out = subprocess.check_output(["pmset", "-g"], text=True, timeout=3)
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("SleepDisabled"):
                return s.split()[-1] == "1"
        return None  # key absent → unknown, not False
    except Exception as e:
        log.error("lid stay-awake state: %s", e)
        return None


def _pmset_disablesleep(val: str) -> int:
    """Run the whitelisted pmset write. Returns the process rc (0 == ok)."""
    try:
        r = subprocess.run(
            ["sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", val],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            log.error("sudo NOPASSWD pmset failed rc=%d stderr=%s — sudoers rule missing?",
                      r.returncode, r.stderr.strip())
        return r.returncode
    except Exception as e:
        log.error("pmset disablesleep %s: %s", val, e)
        return -1


def _set_lid_stay_awake(enabled: bool) -> dict:
    """Set the flag with ownership tracking (A03) and a typed result (A10).

    Records {prev, boot_uuid, set_at} in settings.json the first time WE flip
    OFF→ON, so quit can restore exactly what we changed. Returns
    {desired, native_rc, observed}."""
    before = _lid_stay_awake_state()
    val = "1" if enabled else "0"
    rc = _pmset_disablesleep(val)
    observed = _lid_stay_awake_state()
    if rc == 0 and enabled and before is False:
        # We are the ones enabling it → claim ownership.
        _write_lid_owner({"prev": False, "boot_uuid": _current_boot_uuid(),
                           "set_at": time.time()})
    elif rc == 0 and not enabled:
        # User turned it back off → release any ownership we held.
        _write_lid_owner(None)
    log.info("lid stay-awake desired=%s rc=%d observed=%s", enabled, rc, observed)
    return {"desired": enabled, "native_rc": rc, "observed": observed}


def _read_lid_owner():
    try:
        return json.loads(_SETTINGS.read_text()).get("lid_owner")
    except Exception:
        return None


def _write_lid_owner(record):
    try:
        _SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        data = json.loads(_SETTINGS.read_text()) if _SETTINGS.exists() else {}
        if record is None:
            data.pop("lid_owner", None)
        else:
            data["lid_owner"] = record
        _SETTINGS.write_text(json.dumps(data, indent=2))
    except Exception as e:
        log.error("lid owner write: %s", e)


def _restore_owned_lid_on_quit():
    """On quit, restore disablesleep ONLY if we own it, same boot, and it still
    reads as ON (A03). Otherwise log conflict/stale and touch nothing."""
    owner = _read_lid_owner()
    if not owner:
        return
    if owner.get("boot_uuid") != _current_boot_uuid():
        log.info("[QUIT] lid owner from a previous boot → stale, purging, not touching flag")
        _write_lid_owner(None)
        return
    if _lid_stay_awake_state() is not True:
        log.info("[QUIT] lid flag no longer ON (someone else changed it) → conflict, leaving as-is")
        _write_lid_owner(None)
        return
    log.info("[QUIT] restoring disablesleep to owned prev=%s", owner.get("prev"))
    _pmset_disablesleep("0")
    _write_lid_owner(None)


def _purge_stale_lid_owner_at_launch():
    owner = _read_lid_owner()
    if owner and owner.get("boot_uuid") != _current_boot_uuid():
        log.info("[LAUNCH] purging lid owner from previous boot (never re-applies)")
        _write_lid_owner(None)


# ── Status cache (A09: keep pmset / login-status probes off the UI thread) ────
def _cached_lid_state():
    with _status_lock:
        return _status_cache["lid"]


def _cached_login_status():
    with _status_lock:
        return _status_cache["login"]


def _status_ready() -> bool:
    with _status_lock:
        return _status_cache["ready"]


def _refresh_status_cache(delegate=None):
    """Blocking probe — MUST run in a background thread. Fills the cache, then (if
    a delegate is given) asks the main thread to rebuild the panel if visible."""
    lid = _lid_stay_awake_state()
    login = _login_item_status_str()
    with _status_lock:
        _status_cache["lid"] = lid
        _status_cache["login"] = login
        _status_cache["ready"] = True
    if delegate is not None:
        try:
            delegate.performSelectorOnMainThread_withObject_waitUntilDone_(
                "refreshFromStatusCache:", None, False)
        except Exception:
            pass


def _start_status_refresh(delegate=None):
    threading.Thread(target=_refresh_status_cache, args=(delegate,), daemon=True).start()


def _build_right_click_menu(delegate):
    menu = NSMenu.alloc().init()

    login_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        _("menu.open_at_login", "Open at Login"), "toggleLoginItem:", ""
    )
    login_item.setTarget_(delegate)
    if _cached_login_status() == "enabled":  # A09: cache, no subprocess here
        login_item.setState_(NSControlStateValueOn)
    menu.addItem_(login_item)

    lid_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        _("menu.keep_awake_lid_closed", "Keep awake with lid closed"), "toggleLidStayAwake:", ""
    )
    lid_item.setTarget_(delegate)
    if _cached_lid_state() is True:  # A09/A10: cached tri-state
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

    _screen_change_timer = None

    def applicationDidFinishLaunching_(self, notification):
        AppDelegate.shared = self
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        ensure_status_item(self)
        _purge_stale_lid_owner_at_launch()  # A03: never re-apply a prior boot's flag
        self._reactivate_owned_displays()   # A04: restore displays we disabled last run
        status_now = _login_item_status_str()
        # A17: only self-heal when the registration was actually LOST (notFound =
        # signature changed by rebuild). notRegistered / requiresApproval are the
        # user's own choice and must NOT be silently re-registered.
        _wants_li = _read_wants_login_item()
        if _wants_li is None:
            _write_wants_login_item(status_now == "enabled")
        elif _wants_li and status_now == "notFound":
            _set_login_item(True)
            log.info("[SELF-HEAL] login item re-registered (signature changed by rebuild)")
        log.info("Started. Displays: %s | SkyLight=%s CoreDisplay=%s | LoginItem=%s",
                 list_all_online_displays(), _sls is not None, _cd is not None, status_now)
        NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "screensDidChange:", NSApplicationDidChangeScreenParametersNotification, None
        )
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            5.0, self, "pollScreens:", None, True
        )
        _start_status_refresh(self)  # A09: warm the pmset/login cache off-thread

    @objc.python_method
    def _reactivate_owned_displays(self):
        """A04: displays WE disabled are persisted; on launch try to re-enable
        them with a read-back, logging DONE/FAILED. Prevents an owned display from
        staying dark across a restart with no way back."""
        owned = []
        try:
            owned = json.loads(_SETTINGS.read_text()).get("owned_disabled_displays", [])
        except Exception:
            pass
        for did in list(owned):
            ok = _sls_set_display_enabled(int(did), True)
            online = did in list_all_online_displays()
            log.info("[LAUNCH] re-enable owned display %s: sls_ok=%s online=%s → %s",
                     did, ok, online, "DONE" if online else "FAILED")
        if owned:
            self._persist_owned_disabled()  # rewrite from current disabled_displays

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
        _restore_owned_lid_on_quit()  # A03: restore disablesleep only if WE own it

    @objc.python_method
    def _persist_owned_disabled(self):
        try:
            _SETTINGS.parent.mkdir(parents=True, exist_ok=True)
            data = json.loads(_SETTINGS.read_text()) if _SETTINGS.exists() else {}
            data["owned_disabled_displays"] = [d for d, v in disabled_displays.items() if v]
            _SETTINGS.write_text(json.dumps(data, indent=2))
        except Exception as e:
            log.error("persist owned displays: %s", e)

    def refreshFromStatusCache_(self, _sender):
        # A09: called on the main thread once the background probe finished.
        ensure_status_item(self)
        if self._panel_visible:
            _show_popup(self)

    def screensDidChange_(self, notification):
        # A19: coalesce bursts of screen-parameter changes into one refresh.
        if self._screen_change_timer is not None:
            try:
                self._screen_change_timer.invalidate()
            except Exception:
                pass
        self._screen_change_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.3, self, "delayedRefresh:", None, False
        )

    def delayedRefresh_(self, timer):
        self._screen_change_timer = None
        ensure_status_item(self)
        if self._panel_visible:
            _show_popup(self)

    def pollScreens_(self, timer):
        # A19: the 5s timer only refreshes the menu-bar icon (cheap, no subprocess);
        # it exists because Bartender can collapse/restore the status item.
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
        currently = _cached_login_status() == "enabled"
        _set_login_item(not currently)
        _write_wants_login_item(not currently)
        log.info("Login item: %s → %s", currently, not currently)
        _start_status_refresh(self)  # A09: refresh cache after the change

    def toggleLidStayAwake_(self, sender):
        currently = _cached_lid_state()
        if currently is None:
            log.warning("lid state unknown → ignoring toggle (A10)")
            return
        res = _set_lid_stay_awake(not currently)
        log.info("Lid stay-awake: %s → %s (%s)", currently, not currently, res)
        _start_status_refresh(self)

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
            # A04: recompute topology AT THE MOMENT OF THE EFFECT — not at render.
            # A stale control (e.g. a screen unplugged since the panel was drawn)
            # must not disable the only remaining active display.
            active = [int(s.deviceDescription().get("NSScreenNumber", 0)) for s in NSScreen.screens()]
            active = [d for d in active if not disabled_displays.get(d, False)]
            if display_id not in active:
                log.warning("[DISABLE] display %d not active now — refusing", display_id)
                _show_popup(self)
                return
            if len(active) <= 1:
                log.warning("[DISABLE] display %d is the last active one — refusing", display_id)
                _show_popup(self)
                return
            if _sls_set_display_enabled(display_id, False):
                disabled_displays[display_id] = True
                self._persist_owned_disabled()
        else:
            if _sls_set_display_enabled(display_id, True):
                disabled_displays[display_id] = False
                self._persist_owned_disabled()
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
            res = set_display_resolution(display_id, w, h)  # A05: typed result
            if not res.get("ok"):
                log.warning("[RES] display %d → %dx%d FAILED: %s",
                            display_id, w, h, res.get("error") or res)
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
