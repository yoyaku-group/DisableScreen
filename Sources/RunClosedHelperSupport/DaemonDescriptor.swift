import Foundation

/// A14 — LaunchDaemon helper descriptor (ADR 016).
///
/// The privileged helper is a plain LaunchDaemon registered through
/// `SMAppService.daemon(plistName:)` (macOS 13+, our floor is 14). Apple has
/// deprecated both `SMJobBless` and `AuthorizationExecuteWithPrivileges` in
/// favor of exactly this path — this module is the ONLY surface allowed to
/// know the daemon's identity.
///
/// Layout (inside the future signed app bundle):
///   Contents/MacOS/RunClosed                      — the app
///   Contents/Library/LaunchDaemons/<plist name>   — the daemon plist
///   Contents/Library/LaunchDaemons/<helper name>  — the root helper binary
///
/// The plist's `Program` key points at the helper binary next to it; the
/// daemon runs as root once the USER has approved it in System Settings
/// (Login Items & Extensions). `requiresApproval` is an expected, handled
/// state — the app surfaces `SMAppService.openSystemSettingsLoginItems()`.
public enum RunClosedHelperDescriptor {

    /// The LaunchDaemon plist filename (must match the file shipped in
    /// `Contents/Library/LaunchDaemons/`).
    public static let plistName = "com.benjaminbelaga.runclosed.helper.plist"

    /// The root helper binary filename (bundled next to the plist).
    public static let helperBinaryName = "runclosed-privileged-helper"

    /// The daemon label (= plist `Label` key). Kept in one place so the
    /// plist template and the code can never drift apart.
    public static let daemonLabel = "com.benjaminbelaga.runclosed.helper"

    /// The ONE privileged primitive the daemon is allowed to perform (ADR 016
    /// bounded API): flip `pmset -a disablesleep`. Anything else — generic
    /// exec, shell, arbitrary paths/args, sudo, other pmset settings — is
    /// FORBIDDEN by design and absent from the codebase on purpose.
    public static let boundedOperation = "/usr/bin/pmset -a disablesleep <0|1>"
}
