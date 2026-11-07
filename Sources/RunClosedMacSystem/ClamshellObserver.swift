import Foundation
import IOKit
import RunClosedCore

/// Read-only clamshell (lid) state + display attachment (ADR 025).
///
/// The repository had no clamshell detection before this lot: `PowerReadback`
/// reads the `disablesleep` flag, which says nothing about whether the lid is
/// shut. The thermal rule needs both — heat only matters when nothing is
/// cooling the machine, and that is exactly "lid closed AND no display
/// attached".
///
/// Two readings, both honest about missing data (ADR 009):
///
/// - `lidClosed` — `AppleClamshellState` on `IOPMrootDomain`. `nil` when the
///   property is absent or unreadable; the policy refuses to release on `nil`.
/// - `externalDisplayConnected` — any online display that is not the built-in
///   panel, from `DisplayInventory`. `nil` when the inventory cannot be read,
///   which the policy treats exactly like "attached": in doubt, do not release.
public enum ClamshellReadback {

    /// The IOPMrootDomain property carrying the clamshell bit.
    public static let clamshellKey = "AppleClamshellState"

    /// Pure parser for the property value. `nil` = no reading.
    ///
    /// The property is a `CFBoolean` in practice; an `NSNumber` covers the case
    /// where IOKit hands back an integer 0/1 instead.
    public static func parseLidClosed(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    /// Live read of `AppleClamshellState`.
    public static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, clamshellKey as CFString, kCFAllocatorDefault, 0)
        guard let property else { return nil }
        return parseLidClosed(property.takeRetainedValue())
    }

    /// Attachment reading. `true` = at least one online display that is not the
    /// built-in panel. An empty inventory reads `nil` (unknown), which the
    /// policy treats as attached — the conservative side.
    public static func externalDisplayConnected() -> Bool? {
        let displays = DisplayInventory.snapshot()
        guard !displays.isEmpty else { return nil }
        return displays.contains { !$0.identity.isBuiltin }
    }

    /// Both readings in the shape `ThermalPolicy.Input` wants.
    public static func observe() -> (lidClosed: Bool?, externalDisplayConnected: Bool?) {
        (lidClosed(), externalDisplayConnected())
    }
}

/// The ONE clamshell notification observer (ADR 025).
///
/// `IOPMrootDomain` publishes `kIOPMMessageClamshellStateChange` when the lid
/// moves. Two properties make it usable:
///
/// - **2 s debounce.** Closing the lid produces a burst of messages (state
///   change, display disconnect, sleep assertion changes). Acting on the first
///   one would read a half-updated world; the debounce collapses the burst into
///   one tick, and a later message inside the window restarts it.
/// - **A fallback re-read.** A notification can be MISSED across a sleep, so
///   the app's existing 5 s refresh also re-reads the state
///   (`ClamshellReadback.observe()`), which is why the observer's cached value
///   is refreshed from two places rather than trusted from the notification
///   alone.
///
/// The observer holds no policy and makes no decision: it says when the lid
/// may have changed, and the shared guard tick re-reads and re-decides.
public final class ClamshellObserver: @unchecked Sendable {

    /// The burst window, in seconds.
    public static let debounceSeconds: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.benjaminbelaga.RunClosed.thermal.clamshell")
    private var notifier: io_object_t = IO_OBJECT_NULL
    /// The port backing `notifier`. Kept only so `stop()` can destroy it; the
    /// notifier object itself is released first.
    private var retainedPort: IONotificationPortRef?
    private var pending: DispatchWorkItem?
    private var handler: (@Sendable () -> Void)?

    public init() {}

    /// Install the IOKit interest notification. Idempotent.
    ///
    /// `onChange` fires on the observer's own serial queue after the debounce;
    /// callers hop to their own queue from there.
    public func start(_ onChange: @escaping @Sendable () -> Void) {
        queue.sync {
            guard notifier == IO_OBJECT_NULL else { return }
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            guard service != IO_OBJECT_NULL else { return }
            defer { IOObjectRelease(service) }
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            IONotificationPortSetDispatchQueue(port, queue)
            var token: io_object_t = IO_OBJECT_NULL
            let result = IOServiceAddInterestNotification(
                port, service, kIOGeneralInterest,
                { context, _, _, _ in
                    guard let context else { return }
                    Unmanaged<ClamshellObserver>.fromOpaque(context)
                        .takeUnretainedValue()
                        .scheduleTick()
                },
                Unmanaged.passUnretained(self).toOpaque(), &token)
            guard result == KERN_SUCCESS else {
                IONotificationPortDestroy(port)
                return
            }
            // Only publish the state once the notification is actually
            // installed: `notifier != IO_OBJECT_NULL` is what `start()` uses to
            // stay idempotent, and a token without port or handler would look
            // started while delivering nothing.
            handler = onChange
            notifier = token
            retainedPort = port
        }
    }

    /// Remove the notification. Safe to call more than once, and safe on an
    /// observer that was never started.
    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            handler = nil
            if notifier != IO_OBJECT_NULL {
                IOObjectRelease(notifier)
                notifier = IO_OBJECT_NULL
            }
            if let port = retainedPort {
                IONotificationPortDestroy(port)
                retainedPort = nil
            }
        }
    }

    /// Collapse a burst of notifications into one tick.
    ///
    /// Runs on the observer queue (from the IOKit callback). A message arriving
    /// inside the window cancels the pending tick and restarts the clock, so
    /// the handler only ever sees the settled state.
    func scheduleTick() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                let handler = self.handler
                self.pending = nil
                handler?()
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: work)
    }

    deinit { stop() }
}
