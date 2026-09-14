import Foundation
import CoreGraphics
import RunClosedCore

/// Backend protocol for the single display-mutation primitive:
/// enable or disable a display by its CGDirectDisplayID. Wrapped so tests can
/// substitute a deterministic fake (live path is BLOCKED_HARDWARE on a
/// 1-display machine, see PROGRESS.md §G2b).
public protocol DisplayMutator: Sendable {
    /// Apply the enable/disable request. Returns a typed OperationResult:
    /// - `.verified`  if the native call succeeded AND read-back confirms
    ///   the new state.
    /// - `.failed`    if the native call returned non-zero (no state change
    ///   claimed) OR if the read-back contradicted the request.
    /// - `.unknown`   if the backend could not be reached (e.g. SkyLight
    ///   unavailable in this process).
    mutating func setEnabled(_ displayID: UInt32, _ enabled: Bool) -> OperationResult
}

// MARK: — Real backend (SkyLight via dlsym)

/// Live backend wrapping `SLSConfigureDisplayEnabled` from the private
/// SkyLight framework. The SkyLight symbol is loaded once at module init via
/// `dlsym` — no entitlements or code-signing changes needed, this is the
/// same path the Python app uses via ctypes.
///
/// If SkyLight cannot be loaded (e.g. running in a sandboxed process or on a
/// macOS version that removed the symbol), every call returns
/// `OperationResult(state: .unknown, nativeRC: nil, readbackOK: false, ...)`.
public struct SLSDisplayMutator: DisplayMutator {

    // SkyLight handle — opened once, kept for the lifetime of the process.
    // `nonisolated(unsafe)` because the handle is set once at module load and
    // never mutated afterward; we accept the theoretical race during first
    // concurrent access in exchange for avoiding a synchronization primitive
    // on every call.
    private nonisolated(unsafe) static let skylightHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    // C signature: `int SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)`
    private typealias SLSFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, Bool) -> Int32

    private static let slsConfigureDisplayEnabled: SLSFn? = {
        guard let handle = skylightHandle else { return nil }
        guard let sym = dlsym(handle, "SLSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(sym, to: SLSFn.self)
    }()

    public init() {}

    public mutating func setEnabled(_ displayID: UInt32, _ enabled: Bool) -> OperationResult {
        // CGDisplayConfigRef is an opaque CFBinaryHeap-like bag — CoreGraphics
        // hands us a pointer that we pass through to SLS. The closure of the
        // config transaction (CGCompleteDisplayConfiguration) is what actually
        // applies the change atomically.
        var config: CGDisplayConfigRef?
        let beginRC = CGBeginDisplayConfiguration(&config)
        guard beginRC == .success, let config = config else {
            return OperationResult(
                requestID: UUID().uuidString,
                action: enabled ? .deactivate : .deactivate,
                state: .failed,
                nativeRC: Int(beginRC.rawValue),
                readbackOK: false,
                error: "CGBeginDisplayConfiguration failed (rc=\(beginRC.rawValue))"
            )
        }
        guard let sls = Self.slsConfigureDisplayEnabled else {
            _ = CGCancelDisplayConfiguration(config)
            return OperationResult(
                requestID: UUID().uuidString,
                action: enabled ? .deactivate : .deactivate,
                state: .unknown,
                nativeRC: nil,
                readbackOK: false,
                error: "SLSConfigureDisplayEnabled symbol unavailable"
            )
        }
        let slsRC = sls(UnsafeMutableRawPointer(config), displayID, enabled)
        if slsRC != 0 {
            _ = CGCancelDisplayConfiguration(config)
            return OperationResult(
                requestID: UUID().uuidString,
                action: enabled ? .deactivate : .deactivate,
                state: .failed,
                nativeRC: Int(slsRC),
                readbackOK: false,
                error: "SLSConfigureDisplayEnabled returned \(slsRC)"
            )
        }
        let completeRC = CGCompleteDisplayConfiguration(config, CGConfigureOption(rawValue: 0))
        if completeRC != .success {
            return OperationResult(
                requestID: UUID().uuidString,
                action: enabled ? .deactivate : .deactivate,
                state: .failed,
                nativeRC: Int(completeRC.rawValue),
                readbackOK: false,
                error: "CGCompleteDisplayConfiguration failed (rc=\(completeRC.rawValue))"
            )
        }
        // Readback: is the display still in the active list after the change?
        // For `enabled = false`, it should be absent; for `enabled = true`,
        // it should be present. We rely on CoreGraphics' CGGetOnlineDisplayList
        // as the readback channel.
        let postActive = DisplayInventory.activeIDs()
        let observed = postActive.contains(displayID)
        let expected = enabled ? observed : !observed   // enabled:true → must be active
        let state: OperationState = expected ? .verified : .failed
        return OperationResult(
            requestID: UUID().uuidString,
            action: enabled ? .deactivate : .deactivate,
            state: state,
            nativeRC: 0,
            readbackOK: expected,
            error: expected ? nil : "readback: target \(displayID) presence=\(observed), expected=\(enabled)"
        )
    }
}

// MARK: — Convenience factory for production wiring

public enum DisplayMutators {
    /// Real production mutator. On a 1-display machine it is still safe to
    /// instantiate — calls will simply be refused by `DisplayMutationPolicy`
    /// before reaching the backend.
    public static func live() -> any DisplayMutator {
        return SLSDisplayMutator()
    }
}
