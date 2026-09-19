import Foundation
import ServiceManagement

/// Login-item control for the bundled app (`SMAppService.mainApp`), replacing
/// the Python launcher's `--register/--status` bridge (A06 identity checks are
/// inherent here — `mainApp` always targets the calling process's app bundle,
/// which is RunClosed.app whether called from the menu-bar app or from the
/// `runclosed-cli` binary living inside the same bundle).
///
/// AppKit-free on purpose (MacSystem discipline): the Login Items settings
/// deep-link opens via `/usr/bin/open` instead of NSWorkspace.
public enum LoginItemControl {

    public enum Status: String, Sendable {
        case enabled, notRegistered, requiresApproval, notFound, unknown
    }

    public static func status() -> Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public static func isEnabled() -> Bool {
        status() == .enabled
    }

    /// True when the toggle can do something meaningful: registered/enabled,
    /// unregistered, or parked behind approval (we can open the pane).
    public static func isActionable() -> Bool {
        switch status() {
        case .enabled, .notRegistered, .requiresApproval: return true
        case .notFound, .unknown: return false
        }
    }

    public static func openApprovalSettings() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]
        try? p.run()
    }

    /// Toggle registration. Returns the resulting state name. When macOS parks
    /// the registration behind user approval, opens the settings pane so the
    /// switch is one gesture away from becoming real.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Status {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if status() == .requiresApproval { openApprovalSettings() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(
                Data("[RunClosed] login item \(enabled ? "register" : "unregister") failed: \(error)\n".utf8))
        }
        return status()
    }
}
