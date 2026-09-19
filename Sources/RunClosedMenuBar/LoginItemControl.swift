import Foundation
import ServiceManagement

/// Login-item control for the bundled app (`SMAppService.mainApp`), replacing
/// the Python launcher's `--register/--status` bridge (A06 identity checks are
/// inherent here — `mainApp` always targets THIS bundle).
enum LoginItemControl {

    static func status() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func isEnabled() -> Bool {
        status() == .enabled
    }

    /// True when the toggle can do something meaningful: registered/enabled,
    /// or unregistered. `requiresApproval` still offers an action (open the
    /// settings pane); `notFound` cannot be fixed by us.
    static func isActionable() -> Bool {
        switch status() {
        case .enabled, .notRegistered, .requiresApproval:
            return true
        case .notFound:
            return false
        @unknown default:
            return false
        }
    }

    static func openApprovalSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspaceShared.open(url)
    }

    /// Toggle registration. Returns the new state to display. When macOS
    /// parks the registration behind user approval, opens the settings pane
    /// so the switch is one gesture away from becoming real.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
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
        return isEnabled()
    }
}

/// Tiny indirection so this file stays AppKit-free-ish (NSWorkspace lives in
/// AppKit; the popup already imports it, this keeps the dependency explicit).
import AppKit

enum NSWorkspaceShared {
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
