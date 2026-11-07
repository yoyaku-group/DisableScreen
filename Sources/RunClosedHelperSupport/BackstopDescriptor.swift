import Foundation

/// ADR 024 — the recovery backstop's LaunchAgent descriptor.
///
/// The backstop is a PER-USER agent, not a root daemon: it runs
/// `runclosed-cli recover --backstop` every 60 s in the user's session, which is
/// exactly the context that can read `~/Library/Application Support/RunClosed`
/// and call `pmset` without `sudo` (releasing `disablesleep` needs no root; only
/// SETTING it does).
///
/// Layout inside the signed app bundle (assembled by
/// `scripts/build-runclosed-app.sh`):
///   Contents/MacOS/runclosed-cli                          — the CLI it runs
///   Contents/Library/LaunchAgents/<plist name>            — the agent plist
///
/// The plist uses `BundleProgram` with a path RELATIVE to the bundle root, the
/// same Apple requirement the helper daemon follows (ADR 017). Registration is
/// `SMAppService.agent(plistName:)` and NEVER `launchctl bootstrap`: a job
/// bootstrapped by hand from a path outside the bundle survives deleting the
/// app, leaving a 60 s timer calling a binary that no longer exists.
public enum RunClosedBackstopDescriptor {

    /// The LaunchAgent plist filename — must match the file shipped in
    /// `Contents/Library/LaunchAgents/` and passed to
    /// `SMAppService.agent(plistName:)`.
    public static let plistName = "com.benjaminbelaga.runclosed.backstop.plist"

    /// The app bundle identifier. `SMAppService.agent(plistName:)` resolves the
    /// plist against the CALLING process's main bundle, so a caller whose bundle
    /// is not this one cannot see the agent and must not report it as "off".
    public static let appBundleIdentifier = "com.benjaminbelaga.RunClosed"

    /// The Label the plist declares. Kept next to `plistName` so the template,
    /// the packaging script and the code cannot drift.
    public static let agentLabel = "com.benjaminbelaga.runclosed.backstop"

    /// The program the agent runs, relative to the bundle root — the same
    /// `runclosed-cli` the packaging script installs (NOT `runclosed`: APFS is
    /// case-insensitive and it would collide with the app binary, ADR 017).
    public static let bundleProgramRelativePath = "Contents/MacOS/runclosed-cli"

    /// The arguments. `recover --backstop` is the only protective command.
    public static let programArguments = ["runclosed-cli", "recover", "--backstop"]

    /// Seconds between runs. One minute: fine enough that a crash costs at
    /// most a minute of unprotected awakedness, coarse enough that the job is
    /// invisible.
    public static let startInterval = 60

    /// What this agent is allowed to do, in one line, for the approval surface:
    /// it can only ever make the Mac LESS awake.
    public static let boundedAction =
        "turn lid stay-awake OFF when a session deadline passed or the battery is critical; never ON"
}
