import Foundation
import ServiceManagement

/// Observable lifecycle state of the ADR 024 recovery backstop, mapped 1:1
/// from `SMAppService` statuses — the same model as the ADR 016 daemon
/// (`DaemonStatus`), for the same reason: every state is surfaced, none is
/// silently normalized into another (ADR 009 honesty).
public enum BackstopStatus: String, Sendable, Equatable, CaseIterable {
    /// No active registration (the steady state after an unregister).
    case notRegistered
    /// Registered and running: the agent fires every 60 s.
    case enabled
    /// Registered but still waiting for the user's approval in System
    /// Settings → Login Items & Extensions. The app MUST surface this and
    /// offer the deep link, never block — and, until it is approved, the
    /// protective net does NOT exist, so the CLI keeps refusing a timed
    /// session when the app is not running.
    case requiresApproval
    /// The framework could not find the service: never registered on this
    /// machine (observed on macOS 26 in ADR 018), or a genuinely broken
    /// registration (bundle moved, plist missing). Registration is attempted
    /// from here too; it is never a phantom "enabled".
    case notFound
    /// Container/OS-level failure we could not classify.
    case unknown

    /// Does the backstop actually protect the Mac right now?
    ///
    /// Only `enabled` does. `requiresApproval` is a real, surfaced state but it
    /// enforces nothing yet, so a caller that relaxes a safety rule on the
    /// strength of this state must not relax it here.
    public var isProtecting: Bool { self == .enabled }

    /// One line for a popup or a CLI, honest about what the state means.
    public var summary: String {
        switch self {
        case .enabled:
            return "on — a session deadline and critical battery are enforced even when RunClosed is closed"
        case .requiresApproval:
            return "off — approve it in System Settings"
        case .notRegistered:
            return "off — not registered"
        case .notFound:
            return "off — the agent is not registered on this Mac"
        case .unknown:
            return "unknown"
        }
    }
}

/// Registration seam for the backstop agent — a protocol so unit tests drive
/// every state deterministically without touching the real `SMAppService`
/// (which requires a signed bundle and a user approval gesture).
public protocol BackstopRegistrar: Sendable {
    func status() -> BackstopStatus
    /// Ask launchd to register the bundled agent. `false` = the call failed AND
    /// the service did not end up pending or enabled.
    func register() -> Bool
    func unregister() -> Bool
    /// Open System Settings → Login Items & Extensions so the user can approve
    /// a `requiresApproval` agent. Performs no privileged work.
    func openLoginItemsSettings()
    /// The operator explicitly turned the backstop off (`backstop unregister`).
    /// The app's automatic registration at launch honours this, so it can never
    /// silently undo that decision. Cleared by an explicit re-register.
    func operatorOptedOut() -> Bool
    func setOperatorOptedOut(_ value: Bool)
}

public extension BackstopRegistrar {
    /// Registrars that do not model the opt-out (test doubles) default to
    /// "no opt-out", so nothing changes for them.
    func operatorOptedOut() -> Bool { false }
    func setOperatorOptedOut(_ value: Bool) {}
}

/// Production registrar wrapping `SMAppService.agent(plistName:)`.
///
/// Apple's API — no `launchctl bootstrap`, which would create a job that
/// outlives the app bundle it points at. `agent(...)` resolves the plist
/// against the calling process's main bundle, so this only works from inside
/// `RunClosed.app` (the app itself, or `runclosed-cli` shipped in
/// `Contents/MacOS`), never from a bare `swift run` binary.
public struct SMAppServiceAgentRegistrar: BackstopRegistrar {

    public init() {}

    public func status() -> BackstopStatus {
        Self.map(SMAppService.agent(plistName: RunClosedBackstopDescriptor.plistName).status)
    }

    /// One mapping for the live call AND the fake-driven tests, so no state can
    /// be handled in one place and forgotten in the other.
    public static func map(_ status: SMAppService.Status) -> BackstopStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    @discardableResult
    public func register() -> Bool {
        let service = SMAppService.agent(plistName: RunClosedBackstopDescriptor.plistName)
        do {
            try service.register()
            return true
        } catch {
            // macOS reality (ADR 018, observed for a daemon and kept here for
            // the agent): the first `register()` can throw
            // `SMAppServiceErrorDomain code 1` ("Operation not permitted")
            // WHILE still transitioning to `requiresApproval` — the user
            // approval gate IS the normal path, not a failure. Report failure
            // only when the service did not end up pending/enabled.
            switch service.status {
            case .requiresApproval, .enabled: return true
            default: return false
            }
        }
    }

    @discardableResult
    public func unregister() -> Bool {
        do {
            try SMAppService.agent(plistName: RunClosedBackstopDescriptor.plistName).unregister()
            return true
        } catch {
            return false
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Persisted in `UserDefaults`, NOT in the registry: the opt-out is the
    /// operator's statement of intent and must survive the status going to
    /// `notRegistered`, which is precisely the state that would otherwise look
    /// like "never registered, safe to register at launch".
    public func operatorOptedOut() -> Bool {
        Self.defaults()?.bool(forKey: Self.optedOutKey) ?? false
    }

    public func setOperatorOptedOut(_ value: Bool) {
        Self.defaults()?.set(value, forKey: Self.optedOutKey)
    }

    static let optedOutKey = "backstopOperatorOptedOut"

    /// Same bundle dance as `LowBatteryGuardSettings`: inside the bundle the
    /// main bundle id IS the suite, and `UserDefaults(suiteName: <own id>)` is
    /// rejected by Foundation there.
    private static func defaults() -> UserDefaults? {
        if Bundle.main.bundleIdentifier == "com.benjaminbelaga.RunClosed" {
            return .standard
        }
        return UserDefaults(suiteName: "com.benjaminbelaga.RunClosed")
    }
}

/// Registration + status, deliberately without any mutation of the flag: this
/// is the surface the app, the CLI and `doctor` share.
public struct BackstopLifecycleService {
    public let registrar: any BackstopRegistrar

    public init(registrar: any BackstopRegistrar) {
        self.registrar = registrar
    }

    public struct Report: Sendable, Equatable {
        public var status: BackstopStatus
        /// The ONE thing the agent may do (it can only make the Mac less
        /// awake) — so approving it is an informed decision.
        public var boundedAction: String
        public var intervalSeconds: Int
        /// Result of the last mutating call; nil when only observing. A failed
        /// call is surfaced, never swallowed into a bare status.
        public var lastOperationSucceeded: Bool?

        public var isProtecting: Bool { status.isProtecting }
    }

    public func report() -> Report {
        Report(status: registrar.status(),
               boundedAction: RunClosedBackstopDescriptor.boundedAction,
               intervalSeconds: RunClosedBackstopDescriptor.startInterval,
               lastOperationSucceeded: nil)
    }

    /// Register when nothing is registered, and ONLY then: an existing
    /// registration or a pending approval is a state to surface, never to
    /// fight (no register/retry loop). `notFound` is included because macOS 26
    /// reports a never-registered service that way (ADR 018) — without it a
    /// fresh machine would never register at all.
    ///
    /// Idempotent by construction: calling it at every app launch is the
    /// intended use.
    ///
    /// `automatic` says the APP is registering on its own initiative at launch,
    /// as opposed to the operator typing `runclosed backstop register`. The two
    /// cases differ in exactly one way: an automatic call honours the opt-out
    /// an explicit `backstop unregister` recorded, so launching the app can
    /// never silently undo an operator decision (ADR 024).
    public func registerIfNeeded(automatic: Bool = false) -> Report {
        var ok: Bool?
        if automatic, registrar.operatorOptedOut() {
            // The operator turned the backstop off on purpose. Re-registering
            // at launch would undo that with no prompt and no way to tell —
            // the state is surfaced as `notRegistered`, not fought.
            return report()
        }
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

    /// Explicit `runclosed backstop register`: same rule as `registerIfNeeded`
    /// (never re-register a pending approval), but it CLEARS the operator
    /// opt-out — this IS the operator asking for it back.
    public func registerAndReport() -> Report {
        registrar.setOperatorOptedOut(false)
        return registerIfNeeded()
    }

    /// Reversible teardown: no launchd call when nothing is registered. Records
    /// the operator's opt-out so the app's automatic registration at launch
    /// does not put it straight back.
    public func unregisterAndReport() -> Report {
        var ok: Bool?
        // `notFound` is the never-registered state on macOS 26 (ADR 018), so
        // calling `unregister()` there only throws and reports a spurious
        // failure for a no-op teardown.
        switch registrar.status() {
        case .notRegistered, .notFound:
            break
        default:
            ok = registrar.unregister()
        }
        registrar.setOperatorOptedOut(true)
        var r = report()
        r.lastOperationSucceeded = ok
        return r
    }

    public func openApprovalSettings() {
        registrar.openLoginItemsSettings()
    }
}
