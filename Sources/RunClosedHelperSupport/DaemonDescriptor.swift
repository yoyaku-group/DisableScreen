import Foundation

/// A14 — LaunchDaemon helper descriptor (ADR 016 / ADR 017).
///
/// The privileged helper is a plain LaunchDaemon registered through
/// `SMAppService.daemon(plistName:)` (macOS 13+, our floor is 14). Apple has
/// deprecated both `SMJobBless` and `AuthorizationExecuteWithPrivileges` in
/// favor of exactly this path — this module is the ONLY surface allowed to
/// know the daemon's identity.
///
/// Layout inside the signed app bundle (assembled by
/// `scripts/build-runclosed-app.sh`):
///   Contents/MacOS/RunClosed                    — the menu-bar app
///   Contents/MacOS/runclosed-cli                — management CLI, run from
///                                                 inside the bundle
///                                                 (SMAppService resolves
///                                                 the plist against the
///                                                 calling process's main
///                                                 bundle). NOT named
///                                                 `runclosed`: APFS is
///                                                 case-insensitive, so it
///                                                 would collide with
///                                                 `RunClosed`.
///   Contents/MacOS/<helper name>                — the root helper binary
///   Contents/Library/LaunchDaemons/<plist name> — the daemon plist
///
/// The plist uses `BundleProgram` (NOT `Program`): Apple's required form for
/// SMAppService daemons is a path RELATIVE to the bundle root — see
/// `bundleProgramRelativePath`. The daemon runs as root once the USER has
/// approved it in System Settings (Login Items & Extensions).
/// `requiresApproval` is an expected, handled state — surfaces offer
/// `SMAppService.openSystemSettingsLoginItems()` via
/// `HelperLifecycleService.openApprovalSettings()`.
public enum RunClosedHelperDescriptor {

    /// The LaunchDaemon plist filename — must match the file shipped in
    /// `Contents/Library/LaunchDaemons/` and passed to
    /// `SMAppService.daemon(plistName:)`.
    public static let plistName = "com.benjaminbelaga.runclosed.helper.plist"

    /// The root helper binary filename (bundled in `Contents/MacOS/`).
    public static let helperBinaryName = "runclosed-privileged-helper"

    /// The plist's `BundleProgram` value: the helper's path relative to the
    /// bundle root (Apple: "make the path relative to the bundle"). Kept in
    /// one place so the plist and the packaging script can never drift apart
    /// — a unit test asserts the shipped plist matches this value.
    public static let bundleProgramRelativePath = "Contents/MacOS/\(helperBinaryName)"

    /// The daemon label (= plist `Label` key). Kept in one place so the
    /// plist template and the code can never drift apart.
    public static let daemonLabel = "com.benjaminbelaga.runclosed.helper"

    /// The ONE privileged primitive the daemon is allowed to perform (ADR 016
    /// bounded API): flip `pmset -a disablesleep`. Anything else — generic
    /// exec, shell, arbitrary paths/args, sudo, other pmset settings — is
    /// FORBIDDEN by design and absent from the codebase on purpose.
    public static let boundedOperation = "/usr/bin/pmset -a disablesleep <0|1>"
}
