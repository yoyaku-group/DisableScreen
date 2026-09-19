import Foundation
import ServiceManagement

/// Observable lifecycle state of the A14 LaunchDaemon, mapped 1:1 from
/// `SMAppService` statuses (ADR 016). Every state is surfaced — none is
/// silently normalized into another (ADR 009 honesty).
public enum DaemonStatus: String, Sendable, Equatable {
    /// No active registration. On macOS 26 this is the steady state AFTER
    /// an unregister (observed 2026-09-17 on real hardware).
    case notRegistered
    /// Registered and running as root.
    case enabled
    /// Registered but still waiting for the user's approval in System
    /// Settings → Login Items & Extensions. The app MUST offer the deep
    /// link (`SMAppService.openSystemSettingsLoginItems()`), never block.
    /// NOTE (observed 2026-09-17, macOS 26): the first `register()` call for
    /// a daemon may THROW `SMAppServiceErrorDomain code 1` ("Operation not
    /// permitted") while still transitioning the service here — pending
    /// approval is the normal path, not a failure.
    case requiresApproval
    /// The framework could not find the service. Two distinct situations:
    /// (a) a NEVER-registered daemon reads `notFound` on macOS 26 (observed
    /// 2026-09-17 — a healthy fresh bundle, NOT a broken registration), and
    /// (b) a genuinely broken registration (bundle moved / plist missing).
    /// `registerAndReport()` therefore attempts registration from this state
    /// too. NOT a phantom "enabled".
    case notFound
    /// Container/OS-level failure we could not classify.
    case unknown
}

/// Registration seam for the daemon — a protocol so unit tests can drive
/// every status transition deterministically without touching the real
/// `SMAppService` (which requires a signed bundle + user approval).
public protocol DaemonRegistrar: Sendable {
    /// Current registration status of `RunClosedHelperDescriptor.plistName`.
    func status() -> DaemonStatus
    /// Ask launchd to register the bundled daemon. Returns false on failure;
    /// `requiresApproval` afterwards is the normal next state.
    func register() -> Bool
    /// Ask launchd to unregister the daemon (reversible teardown path).
    func unregister() -> Bool
    /// Open System Settings → Login Items & Extensions so the user can
    /// approve a `requiresApproval` daemon (Apple's documented deep link:
    /// `SMAppService.openSystemSettingsLoginItems()`). Observation-free:
    /// performs no privileged work.
    func openLoginItemsSettings()
}

/// Production registrar wrapping `SMAppService.daemon(plistName:)`.
/// Apple's own API — no SMJobBless, no AuthorizationExecuteWithPrivileges
/// (both deprecated; ADR 016).
public struct SMAppServiceDaemonRegistrar: DaemonRegistrar {

    public init() {}

    public func status() -> DaemonStatus {
        switch SMAppService.daemon(plistName: RunClosedHelperDescriptor.plistName).status {
        case .notRegistered: return .notRegistered
        case .enabled:       return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:      return .notFound
        @unknown default:    return .unknown
    }
    }

    @discardableResult
    public func register() -> Bool {
        let service = SMAppService.daemon(plistName: RunClosedHelperDescriptor.plistName)
        do {
            try service.register()
            return true
        } catch {
            // macOS reality (observed 2026-09-17, macOS 26): the first
            // register() call for a daemon can throw
            // `SMAppServiceErrorDomain code 1` ("Operation not permitted")
            // WHILE still transitioning the service to `requiresApproval` —
            // the user-approval gate IS the normal path (ADR 016/018), not a
            // failure. Report failure only when the service did not end up
            // pending/enabled.
            switch service.status {
            case .requiresApproval, .enabled: return true
            default: return false
            }
        }
    }

    @discardableResult
    public func unregister() -> Bool {
        do {
            try SMAppService.daemon(plistName: RunClosedHelperDescriptor.plistName).unregister()
            return true
        } catch {
            return false
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The A14 flow controller: registration + status + health reporting,
/// deliberately WITHOUT XPC in this first tranche (Ben directive: get
/// registration/status working first, add XPC only after — never debug both
/// at once). The eventual XPC surface is enumerated in ADR 016 but NOT
/// implemented here.
public struct HelperLifecycleService {
    public let registrar: any DaemonRegistrar

    public init(registrar: any DaemonRegistrar) {
        self.registrar = registrar
    }

    /// One-shot report for CLI/UI: current status + the bounded operation
    /// this daemon is allowed to perform (so operators can audit what they
    /// are approving).
    public struct Report: Sendable, Equatable {
        public var status: DaemonStatus
        public var boundedOperation: String
        public var xpcImplemented: Bool   // false in this tranche — honest
        /// Result of the last mutating call (register/unregister); nil when
        /// the report only observed state. A failed call is surfaced, never
        /// swallowed into a bare status (ADR 009 honesty).
        public var lastOperationSucceeded: Bool?
    }

    public func report() -> Report {
        return Report(
            status: registrar.status(),
            boundedOperation: RunClosedHelperDescriptor.boundedOperation,
            xpcImplemented: false,
            lastOperationSucceeded: nil
        )
    }

    /// Attempt registration; returns the status AFTER the attempt so the
    /// caller sees `requiresApproval` (the normal path) rather than a bare
    /// boolean. Registration is attempted from `notRegistered` AND from
    /// `notFound`: on macOS 26 a never-registered daemon reads `notFound`
    /// (observed 2026-09-17 on real hardware), so treating only
    /// `notRegistered` as registrable would silently never register on a
    /// fresh machine. An existing registration or a pending approval is a
    /// state to surface, never to fight — no register/retry loop.
    public func registerAndReport() -> Report {
        var ok: Bool? = nil
        switch registrar.status() {
        case .notRegistered, .notFound:
            ok = registrar.register()
        default:
            break
        }
        var r = report()
        r.lastOperationSucceeded = ok
        return r
    }

    /// Reversible teardown: unregister the daemon and report the resulting
    /// status. No-op (no launchd call) when nothing is registered.
    public func unregisterAndReport() -> Report {
        var ok: Bool? = nil
        if registrar.status() != .notRegistered {
            ok = registrar.unregister()
        }
        var r = report()
        r.lastOperationSucceeded = ok
        return r
    }

    /// Open the System Settings deep link for the user-approval step of a
    /// `requiresApproval` daemon (never blocks, never loops).
    public func openApprovalSettings() {
        registrar.openLoginItemsSettings()
    }
}
