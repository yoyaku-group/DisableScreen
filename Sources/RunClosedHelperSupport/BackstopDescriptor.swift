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

    /// Where launchd writes the agent's stdout/stderr (relative to the user's
    /// home, like the plist's `__HOME__` template).
    ///
    /// Never `/tmp`: it is world-writable and sticky, so another local account
    /// could pre-create the name as a symlink and launchd would open it AS THIS
    /// USER. launchd creates the FILE but not the DIRECTORY, and a bundle built
    /// on one machine can be installed on another — so the app and the CLI
    /// create it at runtime instead of trusting the build (review round 9).
    public static let logDirectoryRelativePath = "Library/Logs/RunClosed"

    /// Create the log directory launchd will write into. Idempotent; a failure
    /// is not fatal (the agent still runs, only its diagnostics are lost).
    @discardableResult
    public static func prepareLogDirectory(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> Bool {
        let dir = home.appendingPathComponent(logDirectoryRelativePath, isDirectory: true)
        return (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)) != nil
    }

    /// The agent's own diagnostic file, resolved at RUNTIME under the home of
    /// the user the agent runs as.
    ///
    /// The plist cannot carry this path. `StandardErrorPath` is a fixed byte
    /// string in a signed bundle, so a `__HOME__` substituted at build time
    /// names the BUILD account's home: install a bundle built by another
    /// account and the agent either writes its diagnostics into a directory
    /// this user may not own, or fails the open and loses them. launchd expands
    /// no variable there (review rounds 13-16 flagged it every time).
    ///
    /// So the plist keeps NO log keys and the agent tees its own stderr here
    /// instead. `NSHomeDirectory()` is resolved by the process, which launchd
    /// starts as the right user.
    public static func agentLogURL(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        home.appendingPathComponent(logDirectoryRelativePath, isDirectory: true)
            .appendingPathComponent("backstop.log")
    }

    /// Append one line to the agent log, creating the directory first. Never
    /// throws: a diagnostic that cannot be written must not fail the run — the
    /// protective action is what matters, and this is only its trace.
    ///
    /// `home` is a test seam; production always uses the process's own home.
    public static func appendAgentLog(
        _ line: String,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        prepareLogDirectory(home: home)
        let url = agentLogURL(home: home)
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // First write: create it, owner-only.
            try? data.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
