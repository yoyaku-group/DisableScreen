import Foundation
import RunClosedCore
import RunClosedMacSystem
import RunClosedPersistence
import RunClosedHelperSupport

// RunClosed CLI (provisional). Dependency-free arg parsing (ADR 003).
//   runclosed status   --json
//   runclosed displays --json
//   runclosed doctor   --json
//   runclosed run [--idle-only] [--max <seconds>] -- <cmd> [args...]
//   runclosed run --lid -- <cmd>        → refused (exit 3): CLI lid wrapper not implemented (ADR 007)
//   runclosed restore --owned           → stub (G3): reports, changes nothing
//   runclosed low-battery status        → battery readback + guard decision (read-only, ADR 022)
//   runclosed low-battery simulate <onBattery> <pct> <minutes> → pure decision (never mutates)

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
    // Two distinct facts, reported as such (ADR 020): the app's closed-lid
    // path is qualified live (docs/compatibility/README.md) and mutates
    // through `sudo -n`; the CLI `run --lid` wrapper is a separate feature
    // that is not implemented (ADR 007). A `sudo -l` presence probe was
    // evaluated and rejected — it exits 0 even without NOPASSWD.
    emitJSON([
        "schemaVersion": kSchemaVersion,
        "bootID": clock.bootID,
        "lidStayAwake": PowerReadback.lidStayAwake().map { $0 ? "on" : "off" } ?? "unknown",
        "lid": [
            "backend": "sudo -n /usr/bin/pmset -a disablesleep (app toggle)",
            "qualification": "closed-lid keep-awake qualified live 2026-09-20 (docs/compatibility/README.md; needs the passwordless sudoers drop-in — README)",
            "runLid": "not implemented — `run --lid` exits 3 (ADR 007)",
        ],
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

    // ADR 007: the CLI lid wrapper is not implemented — refuse honestly, do
    // NOT launch the command pretending it is protected. The qualified
    // closed-lid path is the menu-bar app toggle (docs/compatibility).
    if lid {
        FileHandler.err("run --lid refused: the CLI lid wrapper is not implemented (ADR 007); the qualified closed-lid keep-awake path is the menu-bar app toggle. Use --idle-only for idle-sleep prevention.")
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

// ── A14 — privileged helper lifecycle (registration foundation, NO XPC) ─────

func emitHelperReport(_ r: HelperLifecycleService.Report, action: String) {
    var obj: [String: Any] = [
        "schemaVersion": kSchemaVersion,
        "bootID": clock.bootID,
        "action": action,
        "status": r.status.rawValue,
        "boundedOperation": r.boundedOperation,
        "xpcImplemented": r.xpcImplemented,
    ]
    if let ok = r.lastOperationSucceeded { obj["lastOperationSucceeded"] = ok }
    emitJSON(obj)
}

func cmdHelper(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err("usage: runclosed helper <status|register|login-items|unregister>")
        return 64
    }
    let svc = HelperLifecycleService(registrar: SMAppServiceDaemonRegistrar())
    switch sub {
    case "status":
        emitHelperReport(svc.report(), action: "status")
        return 0
    case "register":
        let r = svc.registerAndReport()
        emitHelperReport(r, action: "register")
        return r.lastOperationSucceeded == false ? 5 : 0
    case "login-items":
        // Opens System Settings → Login Items & Extensions (the user step of
        // a requiresApproval daemon). Performs no privileged action.
        svc.openApprovalSettings()
        emitHelperReport(svc.report(), action: "login-items")
        return 0
    case "unregister":
        let r = svc.unregisterAndReport()
        emitHelperReport(r, action: "unregister")
        return r.lastOperationSucceeded == false ? 5 : 0
    default:
        FileHandler.err("usage: runclosed helper <status|register|login-items|unregister>")
        return 64
    }
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
        FileHandler.err("usage: runclosed lid-stay-awake <on|off [--operator]|status>")
        return 64
    }
    // `--operator` = a human's explicit decision (ADR 021): skips the B2
    // ownership gate on `off`. Scripts and agents never pass it.
    let initiator: LidMutationService.Initiator =
        rest.dropFirst().contains("--operator") ? .operatorCommand : .automatic
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
    case "on", "off":
        var svc = makeLidService()
        // Serialised with the app's low-battery guard tick (ADR 022). An
        // explicit lid command supersedes a pending low-battery re-arm: the
        // guard must not flip the flag back afterwards.
        let r = LidWriteLock().withLock { () -> Result<OperationResult, LidMutationError> in
            let res = svc.setEnabled(sub == "on", initiator: initiator)
            LowBatteryLatchStore().operatorCommandFinished(res)
            return res
        }
        return renderLidResult(r, requestedAction: sub)
    default:
        FileHandler.err("usage: runclosed lid-stay-awake <on|off [--operator]|status>")
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
            msg = "refused: B2 invariant — we do not own the disablesleep flag on this boot (set on a previous boot or by another tool). Automatic callers never turn it off; a human can with 'runclosed lid-stay-awake off --operator'."
            code = 3
        case .backendFailed(let m):
            msg = "backend failed: \(m)"
            code = 5
        }
        FileHandler.err(msg)
        return code
    }
}

// ── ADR 022 — low-battery guard (read-only CLI surface) ─────────────────────

func batteryJSON(_ b: BatteryState) -> [String: Any] {
    [
        "onBattery": b.onBattery as Any? ?? NSNull(),
        "chargePercent": b.chargePercent as Any? ?? NSNull(),
        "minutesRemaining": b.minutesRemaining as Any? ?? NSNull(),
        "isCharging": b.isCharging as Any? ?? NSNull(),
        "currentMilliamps": b.currentMilliamps as Any? ?? NSNull(),
        "batteryPresent": b.batteryPresent,
    ]
}

func latchJSON(_ l: LowBatteryPolicy.Latch) -> [String: Any] {
    ["warnedLow": l.warnedLow, "warnedCritical": l.warnedCritical,
     "releasedByGuard": l.releasedByGuard,
     "failedReleaseSleepTried": l.failedReleaseSleepTried]
}

func decisionJSON(_ d: LowBatteryPolicy.Decision) -> [String: Any] {
    ["action": d.action.rawValue, "reason": d.reason.rawValue, "level": d.level.rawValue]
}

func inputJSON(_ i: LowBatteryPolicy.Input) -> [String: Any] {
    [
        "onBattery": i.onBattery as Any? ?? NSNull(),
        "chargePercent": i.chargePercent as Any? ?? NSNull(),
        "minutesRemaining": i.minutesRemaining as Any? ?? NSNull(),
        "lidFlag": i.lidFlag.map { $0 ? "on" : "off" } ?? "unknown",
        "ownership": i.ownership.rawValue,
        "acDraining": i.acDraining as Any? ?? NSNull(),
    ]
}

func lowBatteryThresholdsJSON() -> [String: Any] {
    [
        "warnPercent": LowBatteryPolicy.warnPercent,
        "criticalPercent": LowBatteryPolicy.criticalPercent,
        "criticalMinutes": LowBatteryPolicy.criticalMinutes,
        "rearmPercent": LowBatteryPolicy.rearmPercent,
    ]
}

/// What the guard will do at the critical threshold, in one word.
func lowBatteryProtection(_ i: LowBatteryPolicy.Input) -> String {
    guard let flag = i.lidFlag else { return "unknown-flag: alert only (B1)" }
    guard flag else { return "not-needed: lid stay-awake is off, macOS sleeps on its own" }
    switch i.ownership {
    case .ownedThisBoot: return "armed: release + sleep at critical"
    case .staleRecord: return "armed (emergency): our record is from a previous boot — release + sleep at critical"
    case .notOwned: return "unprotected: flag set by another tool — alert only"
    }
}

/// The one-click remedy when the flag is not owned on this boot.
func lowBatteryRemedy(_ i: LowBatteryPolicy.Input) -> String? {
    guard i.lidFlag == true else { return nil }
    switch i.ownership {
    case .ownedThisBoot:
        return nil
    case .staleRecord:
        return "recoveryPending: switch \"Keep awake with lid closed\" off then on in the popup (or `runclosed-cli lid-stay-awake off --operator && runclosed-cli lid-stay-awake on`) so RunClosed owns it on this boot; until then only the emergency release protects it."
    case .notOwned:
        return "set by another tool: `runclosed-cli lid-stay-awake off --operator` (then `on` if you want RunClosed to own and protect it)."
    }
}

let lowBatteryUsage = """
usage: runclosed low-battery status
       runclosed low-battery simulate <onBattery:true|false|battery|ac> <percent> <minutes|unknown>
                 [--lid on|off|unknown] [--ownership owned|stale|not-owned] [--released] [--ac-draining]
"""

func parseOnBattery(_ s: String) -> Bool? {
    switch s.lowercased() {
    case "true", "battery", "1", "yes": return true
    case "false", "ac", "0", "no": return false
    default: return nil
    }
}

func cmdLowBattery(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err(lowBatteryUsage)
        return 64
    }
    switch sub {
    case "status":
        // Real readback + decision, READ-ONLY: evaluate() never mutates and
        // never writes the latch. Nothing here calls pmset write or sleepnow.
        let svc = LowBatteryGuardService(
            lidService: makeLidService(),
            latchStore: LowBatteryLatchStore(),
            batteryProvider: { BatteryReadback.read() },
            sleeper: PMSetSleeper())
        let e = svc.evaluate()
        let rec = OwnedLidAssertion(currentBootID: clock.bootID).load()
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "bootID": clock.bootID,
            "mode": "status (read-only)",
            "guardEnabled": LowBatteryGuardSettings.isEnabled(),
            "battery": batteryJSON(e.battery),
            "input": inputJSON(e.input),
            "decision": decisionJSON(e.decision),
            "latch": latchJSON(e.latchBefore),
            "lidRecord": [
                "ownedBootID": rec.bootID,
                "ownedByThisBoot": e.input.ownership == .ownedThisBoot,
                "recoveryPending": e.input.ownership == .staleRecord,
            ],
            "protection": lowBatteryProtection(e.input),
            "remedy": lowBatteryRemedy(e.input) as Any? ?? NSNull(),
            "thresholds": lowBatteryThresholdsJSON(),
        ])
        return 0
    case "simulate":
        // Pure decision on injected values — no readback, no mutation, no
        // persistence. Defaults model the 2026-10-14 incident: flag ON and
        // owned on this boot, fresh latch.
        let args = Array(rest.dropFirst())
        guard args.count >= 3,
              let onBattery = parseOnBattery(args[0]),
              let percent = Int(args[1]), (0...100).contains(percent) else {
            FileHandler.err(lowBatteryUsage)
            return 64
        }
        let minutes: Int?
        switch args[2].lowercased() {
        case "unknown", "-", "nil": minutes = nil
        default:
            guard let m = Int(args[2]) else { FileHandler.err(lowBatteryUsage); return 64 }
            minutes = m > 0 ? m : nil   // same rule as the readback: ≤0 = estimating
        }
        var lidFlag: Bool? = true
        var ownership: LowBatteryPolicy.LidOwnership = .ownedThisBoot
        var latch = LowBatteryPolicy.Latch()
        var acDraining: Bool? = nil
        var i = 3
        while i < args.count {
            switch args[i] {
            case "--lid":
                i += 1
                guard i < args.count else { FileHandler.err(lowBatteryUsage); return 64 }
                switch args[i] {
                case "on": lidFlag = true
                case "off": lidFlag = false
                case "unknown": lidFlag = nil
                default: FileHandler.err(lowBatteryUsage); return 64
                }
            case "--ownership":
                i += 1
                guard i < args.count else { FileHandler.err(lowBatteryUsage); return 64 }
                switch args[i] {
                case "owned": ownership = .ownedThisBoot
                case "stale": ownership = .staleRecord
                case "not-owned": ownership = .notOwned
                default: FileHandler.err(lowBatteryUsage); return 64
                }
            case "--released":
                latch.releasedByGuard = true
            case "--ac-draining":
                acDraining = true
            default:
                FileHandler.err(lowBatteryUsage)
                return 64
            }
            i += 1
        }
        let input = LowBatteryPolicy.Input(
            onBattery: onBattery, chargePercent: percent, minutesRemaining: minutes,
            lidFlag: lidFlag, ownership: ownership, acDraining: acDraining)
        let (decision, next) = LowBatteryPolicy.step(input, latch: latch)
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "mode": "simulate (dry-run, pure decision, nothing mutated)",
            "input": inputJSON(input),
            "protection": lowBatteryProtection(input),
            "decision": decisionJSON(decision),
            "latchBefore": latchJSON(latch),
            "latchAfter": latchJSON(next),
            "thresholds": lowBatteryThresholdsJSON(),
        ])
        return 0
    default:
        FileHandler.err(lowBatteryUsage)
        return 64
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

// ── G2d — login item (SMAppService.mainApp of THIS bundle) ───────────────────

func cmdLoginItem(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err("usage: runclosed login-item <status|on|off>")
        return 64
    }
    switch sub {
    case "status":
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "status": LoginItemControl.status().rawValue,
            "actionable": LoginItemControl.isActionable(),
        ])
        return 0
    case "on":
        let s = LoginItemControl.setEnabled(true)
        emitJSON(["schemaVersion": kSchemaVersion, "action": "on", "status": s.rawValue])
        return s == .enabled ? 0 : (s == .requiresApproval ? 4 : 5)
    case "off":
        let s = LoginItemControl.setEnabled(false)
        emitJSON(["schemaVersion": kSchemaVersion, "action": "off", "status": s.rawValue])
        return s == .notRegistered ? 0 : 5
    default:
        FileHandler.err("usage: runclosed login-item <status|on|off>")
        return 64
    }
}


// ── dispatch ─────────────────────────────────────────────────────────────────
let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else {
    FileHandler.err("usage: runclosed <status|displays|doctor|run|restore|disable|enable|lid-stay-awake|login-item|helper|low-battery> [...]")
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
case "login-item": exit(cmdLoginItem(rest))
case "helper":   exit(cmdHelper(rest))
case "low-battery": exit(cmdLowBattery(rest))
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
