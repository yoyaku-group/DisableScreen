import Foundation

// ADR 026 — actions taken when the lid closes during a keep-awake session.
//
// The comfort half of the product: a lid-closed Mac that keeps running under a
// fleet of agents is also a Mac whose speakers play and whose Slack keeps
// notifying. Insomnia does this; RunClosed did not.
//
// The governing principle of this lot is **nothing is touched without a proven
// way back**. That is why the policy below is pure and why the decision is a
// FUNCTION of the four readings plus the journal's own state: whether the
// actions are currently applied is an input, never a guess.

/// Operator settings for the lid-close actions (ADR 026).
///
/// Two switches, deliberately separate:
///
/// - `enabled` is the lot's master switch and is OFF by default. Nothing
///   touches the sound or an app until the operator asks for it.
/// - `pausedApps` is a SEPARATE switch because pausing a process is far more
///   intrusive than muting a device: a SIGSTOPped app stops responding to its
///   own network keepalives. A single switch would make "I want the sound off"
///   also mean "I accept frozen apps".
public struct LidCloseActionSettings: Codable, Equatable, Sendable {
    /// Master switch. Default OFF (ADR 026): a comfort feature that mutates
    /// system state must be opt-in.
    public var enabled: Bool
    /// Mute the default output device while the lid is closed.
    public var muteAudio: Bool
    /// Pause the apps listed in `pausedApps` (its own switch, OFF by default).
    public var pauseApps: Bool
    /// App names to pause, matched against the running process's executable
    /// path. Defaults are the three the plan names; the list is extensible.
    public var pausedApps: [String]

    public static let defaultPausedApps = ["Slack", "Discord", "WhatsApp"]

    public init(enabled: Bool = false,
                muteAudio: Bool = true,
                pauseApps: Bool = false,
                pausedApps: [String] = LidCloseActionSettings.defaultPausedApps) {
        self.enabled = enabled
        self.muteAudio = muteAudio
        self.pauseApps = pauseApps
        self.pausedApps = pausedApps
    }

    /// Tolerant decoding: a key added by a later version must not make the
    /// stored settings read as corrupt (which would silently fall back to the
    /// OFF default and disable a feature the operator turned on).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        muteAudio = try c.decodeIfPresent(Bool.self, forKey: .muteAudio) ?? true
        pauseApps = try c.decodeIfPresent(Bool.self, forKey: .pauseApps) ?? false
        pausedApps = try c.decodeIfPresent([String].self, forKey: .pausedApps)
            ?? LidCloseActionSettings.defaultPausedApps
    }
}

/// Pure policy for the lid-close actions (ADR 026).
///
/// Three conditions, ALL required, and the absence of any one of them is a
/// named refusal — not a silent no-op:
///
/// 1. **a keep-awake session is in progress.** An indefinite session counts:
///    the plan says "a session is in progress", not "a timed session". A
///    session that is PAUSED does not: the flag is off, the Mac is not being
///    held awake, so there is nothing to make comfortable.
/// 2. **the lid is closed** according to `ClamshellObserver`, including its
///    2 s debounce. `nil` (unreadable) refuses: UNKNOWN is never `true`
///    (ADR 009).
/// 3. **no external display is attached.** `nil` counts as ATTACHED — the
///    doubt never touches the machine, which is what protects a docked
///    workstation from being muted the moment the lid comes down.
///
/// Plus the master switch. A Mac docked with the lid closed is therefore never
/// touched, ever: that is the rule that protects the operator's desk setup.
public enum LidCloseActionPolicy {

    public struct Input: Equatable, Sendable {
        /// A keep-awake session exists on disk and is not paused.
        public var sessionActive: Bool
        /// `AppleClamshellState`: `true` closed, `false` open, `nil` unreadable.
        public var lidClosed: Bool?
        /// An online display that is not the built-in panel. `nil` = unknown,
        /// treated exactly like `true`.
        public var externalDisplayConnected: Bool?
        public var settings: LidCloseActionSettings

        public init(sessionActive: Bool,
                    lidClosed: Bool?,
                    externalDisplayConnected: Bool?,
                    settings: LidCloseActionSettings) {
            self.sessionActive = sessionActive
            self.lidClosed = lidClosed
            self.externalDisplayConnected = externalDisplayConnected
            self.settings = settings
        }
    }

    /// What the caller must do now.
    public enum Action: String, Codable, Sendable, Equatable {
        /// Apply whatever `Decision` asks for (idempotent).
        case apply
        /// Undo everything the journal says we did, in the reverse order.
        case undo
        /// Nothing: either the conditions hold and everything is already
        /// applied, or they do not hold and nothing is applied.
        case none
    }

    /// Why. Every refusal has its own name, so a post-mortem reads the cause
    /// instead of "the feature did nothing".
    public enum Reason: String, Codable, Sendable, Equatable {
        /// The three conditions hold and the switch is on.
        case applied
        /// The operator's master switch is off (the default).
        case switchedOff
        /// No keep-awake session is running on disk.
        case noSession
        /// The session exists but is paused (the flag is off): the Mac is not
        /// being kept awake, so there is nothing to make comfortable.
        case sessionPaused
        /// The lid is open.
        case lidOpen
        /// The lid state could not be read.
        case lidUnknown
        /// A display is attached: a docked Mac is never touched.
        case externalDisplay
        /// The display inventory could not be read; unknown counts as attached.
        case displayUnknown
    }

    public struct Decision: Equatable, Sendable {
        public var action: Action
        public var reason: Reason
        /// Whether the audio should be muted by this decision. Only meaningful
        /// for `.apply`.
        public var muteAudio: Bool
        /// Whether apps should be paused by this decision. Only meaningful for
        /// `.apply`, and gated by its OWN switch (ADR 026).
        public var pauseApps: Bool
        /// The app names this decision covers.
        public var appNames: [String]

        public init(action: Action, reason: Reason, muteAudio: Bool = false,
                    pauseApps: Bool = false, appNames: [String] = []) {
            self.action = action
            self.reason = reason
            self.muteAudio = muteAudio
            self.pauseApps = pauseApps
            self.appNames = appNames
        }
    }

    /// One evaluation. Pure: same input, same answer.
    ///
    /// `currentlyApplied` is the journal's own claim, and it is what makes the
    /// undo reachable: when the conditions stop holding, the answer is
    /// `.undo` — never `.none` — for as long as anything is applied. The
    /// reverse is also true and equally important: with nothing applied and the
    /// conditions not holding, the answer is `.none` and nothing is touched
    /// (idempotence, and no error for a lid that closes twice).
    public static func decide(_ input: Input, currentlyApplied: Bool) -> Decision {
        let refusal = refusalReason(input)
        guard let refusal else {
            return Decision(
                action: .apply,
                reason: .applied,
                muteAudio: input.settings.muteAudio,
                pauseApps: input.settings.pauseApps,
                appNames: input.settings.pauseApps ? input.settings.pausedApps : [])
        }
        return Decision(action: currentlyApplied ? .undo : .none, reason: refusal)
    }

    /// The first condition that does not hold, in the order the operator would
    /// reason about them. `nil` = every condition holds.
    ///
    /// The order is load-bearing for the message: an operator who switched the
    /// feature off must read "switched off", not "no session".
    public static func refusalReason(_ input: Input) -> Reason? {
        guard input.settings.enabled else { return .switchedOff }
        guard input.sessionActive else { return .noSession }
        guard let lidClosed = input.lidClosed else { return .lidUnknown }
        guard lidClosed else { return .lidOpen }
        // `nil` is NOT `false`: an unreadable display inventory counts as
        // attached, so the doubt never touches the machine.
        guard let external = input.externalDisplayConnected else { return .displayUnknown }
        guard !external else { return .externalDisplay }
        return nil
    }

    /// Whether the three conditions hold, ignoring the master switch. Exposed
    /// for the UI (the menu item says what will happen) and for the tests.
    public static func conditionsHold(_ input: Input) -> Bool {
        input.sessionActive && input.lidClosed == true && input.externalDisplayConnected == false
    }

    /// Is a keep-awake session IN PROGRESS?
    ///
    /// An INDEFINITE session counts: the plan says "a session is in progress",
    /// not "a timed session", and the plain switch is a session in every other
    /// part of the product (ADR 023). A PAUSED session does not: the flag is
    /// off, the Mac is not being held awake, so there is nothing to make
    /// comfortable.
    public static func sessionIsActive(_ session: KeepAwakeSession?) -> Bool {
        guard let session else { return false }
        return !session.isPaused
    }
}
