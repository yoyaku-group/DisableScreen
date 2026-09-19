import Foundation

/// Native brightness read/write for the built-in display, via the private
/// CoreDisplay framework (same symbols and same dlopen path as the Python
/// DisableScreen app — mutation-inventory M3). External displays have no
/// proven per-monitor write transport on this hardware (M4/A02): callers use
/// the software-dim overlay instead.
///
/// Everything is best-effort and honest: `get` returns nil when the symbol is
/// missing or the value is out of range; `set` returns false when neither
/// backend accepted the write. No broadcast — a call targets exactly one
/// display ID (invariant 1).
public enum DisplayBrightness {

    // MARK: — dlopen plumbing (CoreDisplay exports both symbol families)

    private nonisolated(unsafe) static let coreDisplayHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
    }()

    // DisplayServices family (preferred, same as Python `_ds_get/_ds_set`).
    private typealias DSGetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSetFn = @convention(c) (UInt32, Float) -> Int32

    // CoreDisplay family (fallback, same as Python `CoreDisplay_Display_*`).
    private typealias CDGetFn = @convention(c) (UInt32) -> Double
    private typealias CDSetFn = @convention(c) (UInt32, Double) -> Void

    private static let dsGet: DSGetFn? = {
        guard let h = coreDisplayHandle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: DSGetFn.self)
    }()

    private static let dsSet: DSSetFn? = {
        guard let h = coreDisplayHandle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: DSSetFn.self)
    }()

    private static let cdGet: CDGetFn? = {
        guard let h = coreDisplayHandle, let s = dlsym(h, "CoreDisplay_Display_GetUserBrightness") else { return nil }
        return unsafeBitCast(s, to: CDGetFn.self)
    }()

    private static let cdSet: CDSetFn? = {
        guard let h = coreDisplayHandle, let s = dlsym(h, "CoreDisplay_Display_SetUserBrightness") else { return nil }
        return unsafeBitCast(s, to: CDSetFn.self)
    }()

    /// Whether any native backend loaded — surfaced in `doctor` diagnostics.
    public static var nativeBackendAvailable: Bool {
        (dsGet != nil && dsSet != nil) || (cdGet != nil && cdSet != nil)
    }

    // MARK: — Read / write

    /// Current brightness of a built-in display in 0...1, or nil when the
    /// display is not built-in / the value is unreadable.
    public static func get(builtin displayID: UInt32) -> Double? {
        if let dsGet {
            var v = Float(0)
            if dsGet(displayID, &v) == 0, v >= 0, v <= 1 { return Double(v) }
        }
        if let cdGet {
            let v = cdGet(displayID)
            if v >= 0, v <= 1 { return v }
        }
        return nil
    }

    /// Write brightness to a built-in display. Returns true only when a
    /// backend accepted the call (value clamped to 0...1 first).
    @discardableResult
    public static func set(builtin displayID: UInt32, value: Double) -> Bool {
        let v = max(0.0, min(1.0, value))
        if let dsSet, dsSet(displayID, Float(v)) == 0 { return true }
        if let cdSet {
            cdSet(displayID, v)
            return true
        }
        return false
    }
}
