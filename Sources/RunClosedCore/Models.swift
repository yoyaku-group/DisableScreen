import Foundation

// UI-independent domain model (ADR 002). No AppKit, no direct system calls — the
// system layer produces these values, the CLI/UI consume them. Every persisted
// type carries a schemaVersion so on-disk state can evolve safely.

public let kSchemaVersion = 1

/// Whether a capability is real, absent, only-experimental, or unknown.
/// Invariant 3: `unknown` is neither OFF nor "supported".
public enum CapabilityStatus: String, Codable, Sendable {
    case supported, unsupported, experimental, unknown
}

/// The observable state of a single operation. Invariant: a native error never
/// silently becomes a UI success.
public enum OperationState: String, Codable, Sendable {
    case idle, pending, verified, failed, conflict, unknown
}

/// Distinct power-management operations (invariant 5): they are NOT
/// interchangeable. `sleepAll` covers global posture changes (currently the
/// `pmset disablesleep` flag) distinct from `deactivate` (per-display).
public enum DisplayAction: String, Codable, Sendable {
    case softwareDim, brightness, deactivate, sleepAll
}

/// What a tracked unit of work is doing. Invariant 7: a live process / low CPU
/// does not prove `working`.
public enum WorkState: String, Codable, Sendable {
    case working, waitingForUser, completed, failed, unknown
}

/// Source that justifies keeping the machine awake.
public enum WorkSource: String, Codable, Sendable {
    case wrapper, officialEvent, manual, observation
}

/// A durable-ish display identity. Invariant: a bare CGDirectDisplayID is not a
/// stable identity — two identical monitors with no serial must resolve to
/// `ambiguous`, never to a guessed write target.
public struct DisplayIdentity: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var isBuiltin: Bool
    public var localizedName: String
    public var ambiguous: Bool
    public init(displayID: UInt32, isBuiltin: Bool, localizedName: String, ambiguous: Bool = false) {
        self.displayID = displayID
        self.isBuiltin = isBuiltin
        self.localizedName = localizedName
        self.ambiguous = ambiguous
    }
}

public struct DisplayCapability: Codable, Sendable, Equatable {
    public var brightness: CapabilityStatus
    public var brightnessBackend: String   // "native" | "softwareDim" | "none"
    public var deactivate: CapabilityStatus
    public init(brightness: CapabilityStatus, brightnessBackend: String, deactivate: CapabilityStatus) {
        self.brightness = brightness
        self.brightnessBackend = brightnessBackend
        self.deactivate = deactivate
    }
}

public struct DisplaySnapshot: Codable, Sendable, Equatable {
    public var identity: DisplayIdentity
    public var capability: DisplayCapability
    public var currentMode: String   // "WxH" or "-"
    public init(identity: DisplayIdentity, capability: DisplayCapability, currentMode: String) {
        self.identity = identity
        self.capability = capability
        self.currentMode = currentMode
    }
}

/// Typed result of a mutation (A05 generalized). `ok` is true only when the
/// native call succeeded AND the read-back confirmed the observable outcome.
public struct OperationResult: Codable, Sendable, Equatable {
    public var requestID: String
    public var action: DisplayAction
    public var state: OperationState
    public var nativeRC: Int?
    public var readbackOK: Bool
    public var error: String?
    public init(requestID: String, action: DisplayAction, state: OperationState,
                nativeRC: Int? = nil, readbackOK: Bool = false, error: String? = nil) {
        self.requestID = requestID
        self.action = action
        self.state = state
        self.nativeRC = nativeRC
        self.readbackOK = readbackOK
        self.error = error
    }
}

/// A bounded keep-awake request (invariant 6): authenticated owner, stable
/// identity, monotonic deadline within one boot. A PID alone is not enough.
public struct Lease: Codable, Sendable, Equatable {
    public var schemaVersion: Int = kSchemaVersion
    public var id: String
    public var owner: String
    public var sessionID: String
    public var pid: Int32?
    public var bootID: String
    public var workSource: WorkSource
    public var state: WorkState
    public var requestedIdleSleep: Bool
    public var requestedClosedLid: Bool
    public var deadlineMonotonic: Double   // seconds, monotonic clock, this boot
    public init(id: String, owner: String, sessionID: String, pid: Int32?, bootID: String,
                workSource: WorkSource, state: WorkState, requestedIdleSleep: Bool,
                requestedClosedLid: Bool, deadlineMonotonic: Double) {
        self.id = id; self.owner = owner; self.sessionID = sessionID; self.pid = pid
        self.bootID = bootID; self.workSource = workSource; self.state = state
        self.requestedIdleSleep = requestedIdleSleep; self.requestedClosedLid = requestedClosedLid
        self.deadlineMonotonic = deadlineMonotonic
    }
}

/// Atomic recovery record written before a persistent mutation (A03 generalized).
public struct RecoveryRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int = kSchemaVersion
    public var bootID: String
    public var owner: String
    public var intent: String
    public var referenceState: String
    public init(bootID: String, owner: String, intent: String, referenceState: String) {
        self.bootID = bootID; self.owner = owner; self.intent = intent; self.referenceState = referenceState
    }
}

public struct PolicyDecision: Codable, Sendable, Equatable {
    public var keepAwake: Bool
    public var reason: String
    public init(keepAwake: Bool, reason: String) {
        self.keepAwake = keepAwake; self.reason = reason
    }
}
