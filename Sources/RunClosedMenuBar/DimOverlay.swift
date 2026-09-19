import AppKit

/// Software dimming for displays with no native brightness transport
/// (external monitors on this hardware — M4/A02). A black, click-through,
/// borderless window above everything; alpha = 1 - brightness. Floored so the
/// image never goes fully black, mirroring the Python `DIM_FLOOR`.
///
/// One overlay per display ID; the overlay lives as long as the process.
/// Main-actor bound: NSWindow/NSScreen are main-thread objects, and every
/// caller (the popup delegate) already runs on the main thread.
@MainActor
final class DimOverlayController {

    static let floor = 0.08

    private var windows: [UInt32: NSWindow] = [:]

    /// Brightness value actually applied (post-floor). The UI caches THIS,
    /// never the requested value (A07).
    private(set) var applied: [UInt32: Double] = [:]

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
    }

    private func window(for displayID: UInt32, on screen: NSScreen) -> NSWindow {
        if let w = windows[displayID] { return w }
        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.backgroundColor = .black
        w.alphaValue = 0
        w.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        w.orderFrontRegardless()
        windows[displayID] = w
        return w
    }

    /// Apply dimming; returns the value actually applied (>= floor), or nil
    /// when no overlay could be created for that display.
    @discardableResult
    func apply(displayID: UInt32, value: Double) -> Double? {
        guard let screen = screen(for: displayID) else { return nil }
        let appliedValue = max(Self.floor, min(1.0, value))
        let w = window(for: displayID, on: screen)
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        w.alphaValue = 1.0 - appliedValue
        applied[displayID] = appliedValue
        return appliedValue
    }

    /// Remove the overlay for a display (display now has a native transport
    /// or was disabled). Idempotent.
    func clear(displayID: UInt32) {
        windows.removeValue(forKey: displayID)?.orderOut(nil)
        applied.removeValue(forKey: displayID)
    }

    /// Current applied brightness for a display (1.0 when never dimmed).
    func current(displayID: UInt32) -> Double {
        applied[displayID] ?? 1.0
    }
}
