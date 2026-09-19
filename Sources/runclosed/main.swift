import Foundation
import RunClosedCore
import RunClosedMacSystem
import RunClosedPersistence

// RunClosed CLI (provisional). Dependency-free arg parsing (ADR 003).
//   runclosed status   --json
//   runclosed displays --json
//   runclosed doctor   --json
//   runclosed run [--idle-only] [--max <seconds>] -- <cmd> [args...]
//   runclosed run --lid -- <cmd>        → refused (exit 3): lid backend unqualified
//   runclosed restore --owned           → stub (G3): reports, changes nothing

let clock = SystemClock(bootID: BootID.current())

func emitJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func displaysJSON() -> [[String: Any]] {
    DisplayInventory.snapshot().map { s in
        [
            "displayID": Int(s.identity.displayID),
            "builtin": s.identity.isBuiltin,
            "name": s.identity.localizedName,
            "ambiguous": s.identity.ambiguous,
            "currentMode": s.currentMode,
            "capability": [
                "brightness": s.capability.brightness.rawValue,
                "brightnessBackend": s.capability.brightnessBackend,
                "deactivate": s.capability.deactivate.rawValue,
            ],
        ]
    }
}

func cmdStatus() {
    let engine = LeaseStore(clock: clock).load()
    let decision = engine.decide(clock: clock)
    emitJSON([
        "schemaVersion": kSchemaVersion,
        "bootID": clock.bootID,
        "keepAwake": decision.keepAwake,
        "reason": decision.reason,
        "leases": engine.leases.map { [
            "id": $0.id, "owner": $0.owner, "sessionID": $0.sessionID,
            "state": $0.state.rawValue, "workSource": $0.workSource.rawValue,
            "idleSleep": $0.requestedIdleSleep, "closedLid": $0.requestedClosedLid,
        ] },
    ])
}

func cmdDisplays() { emitJSON(displaysJSON()) }

func cmdDoctor() {
    emitJSON([
        "schemaVersion": kSchemaVersion,
        "bootID": clock.bootID,
        "lidStayAwake": PowerReadback.lidStayAwake().map { $0 ? "on" : "off" } ?? "unknown",
        "lid": ["backend": "unqualified", "note": "closed-lid keep-awake not qualified on this hardware (G3)"],
        "idleAssertion": ["backend": "IOPMAssertionCreateWithName", "capability": "supported"],
        "displays": displaysJSON().count,
    ])
}

func cmdRun(_ rest: [String]) -> Int32 {
    var idleOnly = false, lid = false
    var maxSeconds: Double = 2 * 3600   // ADR: 2h default cap, configurable
    var i = 0
    var cmd: [String] = []
    while i < rest.count {
        let a = rest[i]
        if a == "--" { cmd = Array(rest[(i + 1)...]); break }
        switch a {
        case "--idle-only": idleOnly = true
        case "--lid": lid = true
        case "--max":
            i += 1
            if i < rest.count, let v = Double(rest[i]) { maxSeconds = v }
        default:
            FileHandler.err("unknown flag: \(a)")
            return 64
        }
        i += 1
    }

    // ADR 007: closed-lid backend is not qualified → refuse, do NOT launch the
    // command pretending it is protected.
    if lid {
        FileHandler.err("run --lid refused: closed-lid keep-awake backend is not qualified on this hardware (G3). Use --idle-only for idle-sleep prevention.")
        return 3
    }
    guard !cmd.isEmpty else {
        FileHandler.err("usage: runclosed run [--idle-only] [--max <seconds>] -- <cmd> [args...]")
        return 64
    }
    _ = idleOnly  // in this tranche the only real backend IS the idle assertion

    // Preflight: acquire the public idle assertion.
    let assertion = IdleAssertion()
    guard assertion.acquire(reason: "runclosed run: \(cmd.joined(separator: " "))") else {
        FileHandler.err("preflight failed: could not create idle-sleep assertion")
        return 1
    }

    // Record a bounded lease so `status` can show it while the command runs.
    let store = LeaseStore(clock: clock)
    var engine = store.load()
    let sessionID = "cli-\(ProcessInfo.processInfo.processIdentifier)"
    _ = engine.acquire(owner: "cli", sessionID: sessionID, pid: nil, workSource: .wrapper,
                       idleSleep: true, closedLid: false, ttl: maxSeconds, clock: clock)
    store.save(engine)

    // Launch the child; forward SIGINT/SIGTERM; propagate its exit status.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = cmd
    let sigsrcInt = DispatchSource.makeSignalSource(signal: SIGINT)
    let sigsrcTerm = DispatchSource.makeSignalSource(signal: SIGTERM)
    let forward: (Int32) -> Void = { sig in if child.isRunning { kill(child.processIdentifier, sig) } }
    sigsrcInt.setEventHandler { forward(SIGINT) }
    sigsrcTerm.setEventHandler { forward(SIGTERM) }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    sigsrcInt.resume(); sigsrcTerm.resume()

    func cleanup() {
        assertion.release()
        var e = store.load()
        e.release(owner: "cli", sessionID: sessionID)
        store.save(e)
    }

    do {
        try child.run()
    } catch {
        FileHandler.err("failed to launch: \(error)")
        cleanup()
        return 126
    }
    child.waitUntilExit()
    cleanup()
    return child.terminationStatus
}

enum FileHandler {
    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

// ── G2c — lid stay-awake subcommand ────────────────────────────────────────

/// Build a LidMutationService wired against the production pmset backend
/// and the live PowerReadback prior-state provider.
func makeLidService() -> LidMutationService {
    let store = OwnedLidAssertion(currentBootID: clock.bootID)
    return LidMutationService(
        bootID: clock.bootID,
        mutator: LidAssertions.live(),
        store: store,
        priorProvider: { PowerReadback.lidStayAwake() }
    )
}

func cmdLidStayAwake(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err("usage: runclosed lid-stay-awake <on|off|status>")
        return 64
    }
    switch sub {
    case "status":
        // Read-only — no ownership claim, no mutation. Cross-boot stale
        // records are surfaced as recoveryPending, never silently discarded
        // (ADR 015: BOOT CHANGE ≠ PROOF OF RESTORATION).
        let prior = PowerReadback.lidStayAwake()
        let store = OwnedLidAssertion(currentBootID: clock.bootID)
        let owned = store.load()
        let staleRecoveryPending = owned.ownedEnabled && owned.bootID != clock.bootID
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "bootID": clock.bootID,
            "observed": prior.map { $0 ? "on" : "off" } ?? "unknown",
            "ownedByThisBoot": owned.bootID == clock.bootID && owned.ownedEnabled,
            "recoveryPending": staleRecoveryPending,
            "ownedBootID": owned.bootID,
            "ownedReferenceState": owned.referenceState,
        ])
        return 0
    case "on":
        var svc = makeLidService()
        let r = svc.setEnabled(true)
        return renderLidResult(r, requestedAction: "on")
    case "off":
        var svc = makeLidService()
        let r = svc.setEnabled(false)
        return renderLidResult(r, requestedAction: "off")
    default:
        FileHandler.err("usage: runclosed lid-stay-awake <on|off|status>")
        return 64
    }
}

func renderLidResult(_ r: Result<OperationResult, LidMutationError>, requestedAction: String) -> Int32 {
    switch r {
    case .success(let op):
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "bootID": clock.bootID,
            "action": requestedAction,
            "state": op.state.rawValue,
            "nativeRC": op.nativeRC as Any? ?? NSNull(),
            "readbackOK": op.readbackOK,
        ])
        return 0
    case .failure(let e):
        let msg: String
        let code: Int32
        switch e {
        case .preconditionUnknown:
            msg = "refused: B1 invariant — observed prior state is UNKNOWN (pmset -g did not report SleepDisabled). Cannot mutate without baseline."
            code = 3
        case .noChangeRequested(let target):
            msg = "refused: no-change — flag already at the requested state (\(target ? "on" : "off"))"
            code = 3
        case .notOwned:
            msg = "refused: B2 invariant — we do not own the disablesleep flag on this boot. Only 'on' followed by 'off' is allowed, never a free 'off'."
            code = 3
        case .backendFailed(let m):
            msg = "backend failed: \(m)"
            code = 5
        }
        FileHandler.err(msg)
        return code
    }
}

// ── G2b — display mutation subcommands ───────────────────────────────────────

/// Build a DisplayMutationService wired against the production SLS backend
/// and the live DisplayInventory active-IDs provider.
func makeDisplayService() -> DisplayMutationService {
    let store = OwnedDisabledDisplays(currentBootID: clock.bootID)
    return DisplayMutationService(
        bootID: clock.bootID,
        mutator: DisplayMutators.live(),
        store: store,
        activeIDsProvider: { DisplayInventory.activeIDs() }
    )
}

func parseDisplayID(_ s: String) -> UInt32? {
    return UInt32(s)
}

func cmdDisable(_ rest: [String]) -> Int32 {
    guard let first = rest.first, let id = parseDisplayID(first) else {
        FileHandler.err("usage: runclosed disable <displayID>")
        return 64
    }
    var svc = makeDisplayService()
    switch svc.disable(target: id) {
    case .success(let r):
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "bootID": clock.bootID,
            "action": "disable",
            "displayID": id,
            "state": r.state.rawValue,
            "nativeRC": r.nativeRC as Any? ?? NSNull(),
            "readbackOK": r.readbackOK,
        ])
        return 0
    case .failure(let e):
        let msg: String
        let code: Int32
        switch e {
        case .staleTarget(let did):
            msg = "refused: display \(did) not in the active set (stale target)"
            code = 3
        case .lastActiveDisplay(let did):
            msg = "refused: display \(did) is the last active one — would leave the Mac headless"
            code = 3
        case .unknownTarget(let did):
            msg = "refused: display \(did) not known to the system"
            code = 3
        case .backendFailed(let m):
            msg = "backend failed: \(m)"
            code = 5
        }
        FileHandler.err(msg)
        return code
    }
}

func cmdEnable(_ rest: [String]) -> Int32 {
    guard let first = rest.first, let id = parseDisplayID(first) else {
        FileHandler.err("usage: runclosed enable <displayID>")
        return 64
    }
    var svc = makeDisplayService()
    switch svc.enable(target: id) {
    case .success(let r):
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "bootID": clock.bootID,
            "action": "enable",
            "displayID": id,
            "state": r.state.rawValue,
            "nativeRC": r.nativeRC as Any? ?? NSNull(),
            "readbackOK": r.readbackOK,
        ])
        return 0
    case .failure(let e):
        let msg: String
        let code: Int32
        switch e {
        case .staleTarget(let did):
            msg = "refused: display \(did) not in the active set (stale target)"
            code = 3
        case .lastActiveDisplay:
            // .lastActiveDisplay cannot happen on enable path (only disable
            // can refuse for being last). Keep the branch for completeness.
            msg = "refused: cannot enable (last-active guard)"
            code = 3
        case .unknownTarget(let did):
            msg = "refused: display \(did) not known — not in the owned-disabled record either"
            code = 3
        case .backendFailed(let m):
            msg = "backend failed: \(m)"
            code = 5
        }
        FileHandler.err(msg)
        return code
    }
}

/// Restore all owned-disabled displays — used at launch recovery and as an
/// explicit recovery subcommand. Exit code is part of the contract:
///   - 0   = full restoration (stillOwned empty)
///   - 5   = partial restoration (some ids still owned — JSON `stillOwned`
///           lists them for follow-up; agents/scripts MUST inspect it)
/// A recovery subcommand that returns 0 on partial is dangerous: callers
/// assume success and skip the retry. ADR 014 corrects this.
func cmdRestoreOwned() -> Int32 {
    var svc = makeDisplayService()
    let stillOwned = svc.restoreOwned()
    emitJSON([
        "schemaVersion": kSchemaVersion,
        "bootID": clock.bootID,
        "action": "restore-owned",
        "restored": stillOwned.count == 0 ? "all" : "partial",
        "stillOwned": stillOwned,
    ])
    return stillOwned.isEmpty ? 0 : 5
}


// ── dispatch ─────────────────────────────────────────────────────────────────
let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else {
    FileHandler.err("usage: runclosed <status|displays|doctor|run|restore|disable|enable|lid-stay-awake> [...]")
    exit(64)
}
let rest = Array(args.dropFirst())

switch sub {
case "status":   cmdStatus()
case "displays": cmdDisplays()
case "doctor":   cmdDoctor()
case "run":      exit(cmdRun(rest))
case "disable":  exit(cmdDisable(rest))
case "enable":   exit(cmdEnable(rest))
case "lid-stay-awake": exit(cmdLidStayAwake(rest))
case "restore":
    // restore --owned = re-enable every display we previously disabled (B3).
    // restore --lid = closed-lid keep-awake restore (G3 stub, unchanged).
    if rest.first == "--owned" {
        exit(cmdRestoreOwned())
    }
    FileHandler.err("restore --owned: implemented in G2b. 'restore --lid' remains a G3 stub. No changes made.")
    exit(0)
default:
    FileHandler.err("unknown command: \(sub)")
    exit(64)
}
