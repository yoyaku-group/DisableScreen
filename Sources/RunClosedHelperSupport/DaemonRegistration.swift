import Foundation
import ServiceManagement

/// Observable lifecycle state of the A14 LaunchDaemon, mapped 1:1 from
/// `SMAppService` statuses (ADR 016). Every state is surfaced — none is
/// silently normalized into another (ADR 009 honesty).
public enum DaemonStatus: String, Sendable, Equatable {
    /// Never registered on this machine.
    case notRegistered
    /// Registered and running as root.
    case enabled
    /// Registered but still waiting for the user's approval in System
    /// Settings → Login Items & Extensions. The app MUST offer the deep
    /// link (`SMAppService.openSystemSettingsLoginItems()`), never block.
    case requiresApproval
    /// The registration is broken (bundle moved / plist missing / OS
    /// rejected it). NOT a phantom "enabled".
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
        do {
            try SMAppService.daemon(plistName: RunClosedHelperDescriptor.plistName).register()
            return true
        } catch {
            return false
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
    }

    public func report() -> Report {
        return Report(
            status: registrar.status(),
            boundedOperation: RunClosedHelperDescriptor.boundedOperation,
            xpcImplemented: false
        )
    }

    /// Attempt registration; returns the status AFTER the attempt so the
    /// caller sees `requiresApproval` (the normal path) rather than a bare
    /// boolean.
    public func registerAndReport() -> Report {
        if registrar.status() == .notRegistered {
            _ = registrar.register()
        }
        return report()
    }
}
