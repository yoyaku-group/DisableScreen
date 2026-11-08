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
//   runclosed thermal status            → thermal/clamshell readback + decision (read-only, ADR 025)
//   runclosed thermal simulate <state>  → pure decision (never mutates)

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
        // ADR 024: is anything enforcing a deadline while the app is closed?
        "backstop": backstopJSON(),
    ])
}

func cmdDisplays() { emitJSON(displaysJSON()) }

// ── ADR 024 — recovery backstop registration surface ────────────────────────

func backstopService() -> BackstopLifecycleService {
    BackstopLifecycleService(registrar: SMAppServiceAgentRegistrar())
}

/// The registration state — and, crucially, the PROOF OF EXECUTION — for
/// `status`/`doctor` and for the CLI's own refusals (ADR 024 §5).
///
/// `protecting` deliberately stays the registration fact (`enabled`), because
/// that is what it says. `enforcing` is the stronger claim: registered AND a
/// successful run on this boot within the last 3 minutes. Only `enforcing` may
/// relax a safety rule. Read-only: `status()` performs no registration.
func backstopJSON() -> [String: Any] {
    let report = backstopService().report()
    let heartbeat = BackstopHeartbeatStore().load()
    let freshness = RecoveryPolicy.runFreshness(
        heartbeat: BackstopHeartbeatStore().freshnessInput(),
        currentBootID: clock.bootID,
        now: Date())
    let iso = ISO8601DateFormatter()
    return [
        "status": report.status.rawValue,
        "protecting": report.isProtecting,
        "enforcing": report.isProtecting && freshness.isEnforcing,
        "summary": report.status.summary,
        // Why the app will not register the agent at launch, when it will not.
        // Without this an operator who once ran `backstop unregister` reads
        // "off — not registered" forever and is told to approve an agent that
        // will never appear in System Settings.
        "operatorOptedOut": report.operatorOptedOut,
        "boundedAction": report.boundedAction,
        "intervalSeconds": report.intervalSeconds,
        "lastRunAt": heartbeat.map { iso.string(from: $0.at) } as Any? ?? NSNull(),
        "lastExitCode": heartbeat.map { Int($0.exitCode) } as Any? ?? NSNull(),
        "recentRun": freshness.isEnforcing,
        "runFreshness": String(describing: freshness),
    ]
}

let backstopUsage = """
usage: runclosed backstop status [--json]
       runclosed backstop register          (registers the LaunchAgent; approval may be required)
       runclosed backstop login-items       (opens System Settings → Login Items)
       runclosed backstop unregister
"""

func cmdBackstop(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err(backstopUsage)
        return 64
    }
    let svc = backstopService()
    switch sub {
    case "status":
        let args = Array(rest.dropFirst())
        guard args.isEmpty || args == ["--json"] else {
            FileHandler.err(backstopUsage)
            return 64
        }
        if args == ["--json"] {
            emitJSON([
                "schemaVersion": kSchemaVersion,
                "bootID": clock.bootID,
                "backstop": backstopJSON(),
                "plistName": RunClosedBackstopDescriptor.plistName,
                "agentLabel": RunClosedBackstopDescriptor.agentLabel,
                "bundleProgram": RunClosedBackstopDescriptor.bundleProgramRelativePath,
                "programArguments": RunClosedBackstopDescriptor.programArguments,
            ])
        } else {
            let report = svc.report()
            print("recovery backstop: \(report.status.rawValue) — \(report.status.summary)")
            if report.operatorOptedOut {
                print("  you turned it off (`backstop unregister`); the app will not re-register it at launch. "
                      + "`backstop register` turns it back on.")
            }
        }
        return 0
    case "register":
        guard rest.count == 1 else { FileHandler.err(backstopUsage); return 64 }
        // launchd creates the log FILE but not its directory, and the bundle
        // may have been built on another machine: register is the moment the
        // agent starts writing, so this is where the directory must exist.
        RunClosedBackstopDescriptor.prepareLogDirectory()
        let r = svc.registerAndReport()
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "action": "register",
            "backstop": backstopJSON(),
            "lastOperationSucceeded": r.lastOperationSucceeded as Any? ?? NSNull(),
        ])
        return r.lastOperationSucceeded == false ? 5 : 0
    case "login-items":
        guard rest.count == 1 else { FileHandler.err(backstopUsage); return 64 }
        svc.openApprovalSettings()
        emitJSON(["schemaVersion": kSchemaVersion, "action": "login-items",
                  "backstop": backstopJSON()])
        return 0
    case "unregister":
        guard rest.count == 1 else { FileHandler.err(backstopUsage); return 64 }
        let r = svc.unregisterAndReport()
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "action": "unregister",
            "backstop": backstopJSON(),
            "lastOperationSucceeded": r.lastOperationSucceeded as Any? ?? NSNull(),
        ])
        return r.lastOperationSucceeded == false ? 5 : 0
    default:
        FileHandler.err(backstopUsage)
        return 64
    }
}

/// ADR 024 §5 — may a CLI command that needs an enforcer rely on the backstop?
///
/// Registration alone is NOT enough: `SMAppService` reports `enabled` for an
/// approved agent whose program never actually runs (a `BundleProgram` that
/// does not resolve, a binary removed from the bundle). Trusting that would let
/// `session start --for` through with nothing enforcing the deadline — the
/// silent failure ADR 023 refuses.
///
/// So the agent must be `enabled` AND have written a heartbeat on THIS boot
/// within `RecoveryPolicy.maximumHeartbeatAge` AND that run must not have
/// failed. A pending approval still fails, and so does a stale heartbeat after
/// a wake — conservative, and launchd fires the missed interval on wake, so the
/// next minute restores it.
///
/// Called BEFORE `LidWriteLock`, deliberately: it is an XPC round-trip. The
/// fast local re-check inside the section is `backstopStillEnforcingLocked()`.
func backstopEnforcement() -> RecoveryPolicy.RunFreshness? {
    guard backstopService().report().isProtecting else { return nil }
    return RecoveryPolicy.runFreshness(
        heartbeat: BackstopHeartbeatStore().freshnessInput(),
        currentBootID: clock.bootID,
        now: Date())
}

/// `true` only when the backstop is provably running. See `backstopEnforcement`.
func backstopIsProtecting() -> Bool {
    backstopEnforcement()?.isEnforcing ?? false
}

/// Cheap re-check for use INSIDE `LidWriteLock`.
///
/// `backstopEnforcement()` is an `SMAppService` XPC round-trip, so `start` and
/// `extend` read it BEFORE the lock — holding the lid lock across a slow `smd`
/// stalls the app's guard tick and every other CLI command. That leaves a
/// window: an operator `backstop unregister` completing while this command
/// waits for the lock flipped the agent off, yet the pre-lock answer stayed
/// `true` and a timed session was accepted with nothing enforcing its
/// deadline. The heartbeat's 180 s tolerance does not help — it is tolerance in
/// the OTHER direction.
///
/// So the two facts an unregister actually changes are re-read here, inside the
/// section, at the cost of no XPC at all:
///
/// - the recorded opt-out (`UserDefaults`), which `backstop unregister` sets so
///   the app cannot silently undo it — the same durable signal the app honours;
/// - the heartbeat freshness (`backstop_heartbeat.json`), which is a file read.
///
/// It does not re-ask `SMAppService`, so a revocation made in System Settings
/// during that same window is not covered: that path is asynchronous, leaves no
/// local trace, and closing it would mean putting the XPC back under the lock.
/// The named, local, instant path is closed; the residual is documented in
/// ADR 024 rather than hidden.
func backstopStillEnforcingLocked() -> Bool {
    guard !SMAppServiceAgentRegistrar().operatorOptedOut() else { return false }
    return RecoveryPolicy.runFreshness(
        heartbeat: BackstopHeartbeatStore().freshnessInput(),
        currentBootID: clock.bootID,
        now: Date()).isEnforcing
}

/// The precise reason the backstop cannot be relied on, for the CLI refusal.
///
/// Naming one of five situations beats a generic "not running": the operator's
/// next move differs (approve it / wait a minute / open the app).
func backstopRefusalReason() -> String {
    let status = backstopService().report().status
    guard status.isProtecting else {
        // Name the operator's own decision when that is the reason: telling
        // someone to approve an agent in System Settings that will never be
        // registered there sends them to a screen with nothing to approve.
        if backstopService().report().operatorOptedOut {
            return "you turned the recovery backstop off (`backstop unregister`), so the app will not register it — `runclosed-cli backstop register` turns it back on"
        }
        return "the recovery backstop is not enabled (status: \(status.rawValue)) — approve it in System Settings → Login Items, or open RunClosed"
    }
    let freshness = RecoveryPolicy.runFreshness(
        heartbeat: BackstopHeartbeatStore().freshnessInput(),
        currentBootID: clock.bootID,
        now: Date())
    if freshness.isEnforcing {
        return "the recovery backstop is enabled and running"
    }
    return "the recovery backstop is enabled but not provably running — \(freshness.refusalHint). Wait a minute, or open RunClosed"
}

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
        // ADR 024: the out-of-app safety net. Reported as a fact, with the
        // honest consequence when it is not up.
        "backstop": backstopJSON(),
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

// ── ADR 025 — thermal guard (read-only CLI surface) ─────────────────────────

func thermalJSON(_ s: ThermalState) -> [String: Any] {
    ["state": s.rawValue, "serious": s.isSerious, "critical": s.isCritical]
}

func thermalLatchJSON(_ l: ThermalPolicy.Latch) -> [String: Any] {
    [
        "warnedSerious": l.warnedSerious,
        "warnedCritical": l.warnedCritical,
        "seriousSince": l.seriousSince as Any? ?? NSNull(),
        "seriousSinceBootID": l.seriousSinceBootID as Any? ?? NSNull(),
        "releasedForHeat": l.releasedForHeat,
    ]
}

func thermalDecisionJSON(_ d: ThermalPolicy.Decision) -> [String: Any] {
    ["action": d.action.rawValue, "reason": d.reason.rawValue, "state": d.state.rawValue]
}

/// `closed` / `open` / `unknown` — a script must be able to tell a refusal
/// caused by an open lid from one caused by an unreadable one.
func thermalTriState(_ v: Bool?, yes: String, no: String) -> String {
    guard let v else { return "unknown" }
    return v ? yes : no
}

func thermalInputJSON(_ i: ThermalPolicy.Input) -> [String: Any] {
    [
        "state": i.state.rawValue,
        "lid": thermalTriState(i.lidClosed, yes: "closed", no: "open"),
        "externalDisplay": thermalTriState(i.externalDisplayConnected,
                                           yes: "connected", no: "none"),
        "lidFlag": i.lidFlag.map { $0 ? "on" : "off" } ?? "unknown",
        "ownership": i.ownership.rawValue,
        "enclosed": i.isEnclosed,
        "monotonic": i.monotonic,
        "bootID": i.bootID,
    ]
}

func thermalThresholdsJSON() -> [String: Any] {
    ["sustainedReleaseSeconds": Int(ThermalPolicy.sustainedReleaseSeconds)]
}

/// What the guard will do about the current heat, in one phrase.
func thermalProtection(_ i: ThermalPolicy.Input) -> String {
    guard i.state.isHot else { return "not-needed: the machine is not hot" }
    guard let flag = i.lidFlag else { return "unknown-flag: alert only (B1)" }
    guard flag else { return "not-needed: lid stay-awake is off, macOS sleeps and cools on its own" }
    guard i.lidClosed == true else {
        return i.lidClosed == false
            ? "not-needed: lid open — the air circulates and the operator is there"
            : "unknown-lid: alert only (a lid that cannot be read is not proven shut)"
    }
    guard i.externalDisplayConnected == false else {
        return i.externalDisplayConnected == true
            ? "not-needed: a display is attached, so the machine is in use"
            : "unknown-display: alert only (in doubt, do not release)"
    }
    switch i.ownership {
    case .ownedThisBoot:
        return i.state.isCritical
            ? "armed: release + sleep now (critical, nothing is cooling it)"
            : "armed: release + sleep once serious has held for \(Int(ThermalPolicy.sustainedReleaseSeconds / 60)) min"
    case .staleRecord:
        return "unprotected: our record is from a previous boot — alert only (the heat rule has no emergency widening)"
    case .notOwned:
        return "unprotected: flag set by another tool — alert only"
    }
}

/// The one-click remedy when the flag is not provably ours.
func thermalRemedy(_ i: ThermalPolicy.Input) -> String? {
    guard i.state.isHot, i.lidFlag == true else { return nil }
    switch i.ownership {
    case .ownedThisBoot:
        return nil
    case .staleRecord:
        return "recoveryPending: switch \"Keep awake with lid closed\" off then on in the popup (or `runclosed-cli lid-stay-awake off --operator && runclosed-cli lid-stay-awake on`) so RunClosed owns it on this boot; until then the thermal guard can only alert."
    case .notOwned:
        return "set by another tool: `runclosed-cli lid-stay-awake off --operator` (then `on` if you want RunClosed to own and protect it)."
    }
}

let thermalUsage = """
usage: runclosed thermal status [--json]
       runclosed thermal simulate <nominal|fair|serious|critical>
                 [--lid closed|open|unknown] [--external-display yes|no|unknown]
                 [--lid-flag on|off|unknown] [--ownership owned|stale|not-owned]
                 [--since <seconds-ago>]

`simulate` is a pure decision on injected values: it never reads the flag,
never writes the latch, and never sleeps the Mac.
"""

func parseThermalState(_ s: String) -> ThermalState? {
    ThermalState(rawValue: s.lowercased())
}

func cmdThermal(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err(thermalUsage)
        return 64
    }
    switch sub {
    case "status":
        // Real readback + decision, READ-ONLY: `evaluate()` never mutates,
        // never writes the latch, and never sleeps the Mac.
        let svc = ThermalGuardService(
            lidService: makeLidService(),
            latchStore: ThermalLatchStore(),
            thermalProvider: { ThermalReadback.read() },
            lidClosedProvider: { ClamshellReadback.lidClosed() },
            externalDisplayProvider: { ClamshellReadback.externalDisplayConnected() },
            monotonic: { MonotonicReadback.seconds() },
            sleeper: PMSetSleeper())
        let e = svc.evaluate()
        let rec = OwnedLidAssertion(currentBootID: clock.bootID).load()
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "bootID": clock.bootID,
            "mode": "status (read-only)",
            "guardEnabled": ThermalGuardSettings.isEnabled(),
            "thermal": thermalJSON(e.input.state),
            "input": thermalInputJSON(e.input),
            "decision": thermalDecisionJSON(e.decision),
            "latch": thermalLatchJSON(e.latchBefore),
            "lidRecord": [
                "ownedBootID": rec.bootID,
                "ownedByThisBoot": e.input.ownership == .ownedThisBoot,
                "recoveryPending": e.input.ownership == .staleRecord,
            ],
            "protection": thermalProtection(e.input),
            "remedy": thermalRemedy(e.input) as Any? ?? NSNull(),
            "thresholds": thermalThresholdsJSON(),
        ])
        return 0

    case "simulate":
        // Pure decision on injected values — no readback, no mutation, no
        // persistence, no sleep. Defaults model the incident shape: lid closed,
        // no display, flag ON and ours.
        let args = Array(rest.dropFirst())
        guard let first = args.first, let state = parseThermalState(first) else {
            FileHandler.err(thermalUsage)
            return 64
        }
        var lidClosed: Bool? = true
        var externalDisplay: Bool? = false
        var lidFlag: Bool? = true
        var ownership: LowBatteryPolicy.LidOwnership = .ownedThisBoot
        var latch = ThermalPolicy.Latch()
        var monotonic: Double = 1_000
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--lid":
                i += 1
                guard i < args.count else { FileHandler.err(thermalUsage); return 64 }
                switch args[i] {
                case "closed": lidClosed = true
                case "open": lidClosed = false
                case "unknown": lidClosed = nil
                default: FileHandler.err(thermalUsage); return 64
                }
            case "--external-display":
                i += 1
                guard i < args.count else { FileHandler.err(thermalUsage); return 64 }
                switch args[i] {
                case "yes", "connected", "true": externalDisplay = true
                case "no", "none", "false": externalDisplay = false
                case "unknown": externalDisplay = nil
                default: FileHandler.err(thermalUsage); return 64
                }
            case "--lid-flag":
                i += 1
                guard i < args.count else { FileHandler.err(thermalUsage); return 64 }
                switch args[i] {
                case "on": lidFlag = true
                case "off": lidFlag = false
                case "unknown": lidFlag = nil
                default: FileHandler.err(thermalUsage); return 64
                }
            case "--ownership":
                i += 1
                guard i < args.count else { FileHandler.err(thermalUsage); return 64 }
                switch args[i] {
                case "owned": ownership = .ownedThisBoot
                case "stale": ownership = .staleRecord
                case "not-owned": ownership = .notOwned
                default: FileHandler.err(thermalUsage); return 64
                }
            case "--since":
                // Paint an open `serious` episode: the tick's `monotonic` is
                // then `since` seconds past the latch's start.
                i += 1
                guard i < args.count, let s = Double(args[i]), s.isFinite, s >= 0 else {
                    FileHandler.err(thermalUsage)
                    return 64
                }
                monotonic = 1_000 + s
                latch = ThermalPolicy.Latch(
                    seriousSince: 1_000, seriousSinceBootID: clock.bootID)
            default:
                FileHandler.err(thermalUsage)
                return 64
            }
            i += 1
        }
        let input = ThermalPolicy.Input(
            state: state, lidClosed: lidClosed, externalDisplayConnected: externalDisplay,
            lidFlag: lidFlag, ownership: ownership, monotonic: monotonic,
            bootID: clock.bootID)
        let (decision, next) = ThermalPolicy.step(input, latch: latch)
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "mode": "simulate (dry-run, pure decision, nothing mutated)",
            "input": thermalInputJSON(input),
            "protection": thermalProtection(input),
            "decision": thermalDecisionJSON(decision),
            "latchBefore": thermalLatchJSON(latch),
            "latchAfter": thermalLatchJSON(next),
            "thresholds": thermalThresholdsJSON(),
        ])
        return 0

    default:
        FileHandler.err(thermalUsage)
        return 64
    }
}

// ── ADR 023 — timed keep-awake session ──────────────────────────────────────

let sessionUsage = """
usage: runclosed session start --for <2h|90m|1h30m>   (bare number = minutes)
       runclosed session start --indefinite          (the plain switch)
       runclosed session extend [30m]
       runclosed session end [--operator]            (--operator: a human turning off a flag RunClosed did not set)
       runclosed session status [--json]
"""

func sessionJSON(_ session: KeepAwakeSession?, now: SessionPolicy.Now) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    guard let s = session else {
        return ["present": false]
    }
    var obj: [String: Any] = [
        "present": true,
        "schemaVersion": s.schemaVersion,
        "id": s.id.uuidString,
        "startedAt": iso.string(from: s.startedAt),
        "bootID": s.bootID,
        "indefinite": s.isIndefinite,
        "pausedReason": s.pausedReason?.rawValue as Any? ?? NSNull(),
        "onThisBoot": s.isOnBoot(now.bootID),
        "due": SessionPolicy.isDue(s, now: now),
        "dueReason": SessionPolicy.dueReason(s, now: now)?.rawValue as Any? ?? NSNull(),
        "remainingSeconds": SessionPolicy.remaining(s, now: now) as Any? ?? NSNull(),
        "remainingLabel": SessionPolicy.remainingLabel(s, now: now) as Any? ?? NSNull(),
        "endsAtWall": s.endsAtWall.map { iso.string(from: $0) } as Any? ?? NSNull(),
        "endsAtContinuous": s.endsAtContinuous as Any? ?? NSNull(),
    ]
    // Only meaningful on the boot that wrote the counter.
    if s.isOnBoot(now.bootID), let deadline = s.endsAtContinuous {
        obj["continuousDeadlineSecondsFromNow"] =
            deadline > now.continuousNanoseconds
            ? ContinuousClockTimebase.seconds(fromNanoseconds: deadline - now.continuousNanoseconds)
            : 0
    }
    return obj
}

/// One line a script can read without a JSON parser.
func sessionHumanLine(_ session: KeepAwakeSession?, now: SessionPolicy.Now) -> String {
    guard let s = session else { return "no session" }
    if s.isIndefinite {
        return "indefinite session (started \(ISO8601DateFormatter().string(from: s.startedAt)))"
    }
    if SessionPolicy.isDue(s, now: now) {
        return "due (\(SessionPolicy.dueReason(s, now: now)?.rawValue ?? "-")) — ends on the next tick"
    }
    let left = SessionPolicy.remainingLabel(s, now: now) ?? "-"
    let paused = s.pausedReason.map { " (paused: \($0.rawValue))" } ?? ""
    return "running: \(left)\(paused)"
}

func makeSessionService() -> SessionService {
    SessionService.live(bootID: clock.bootID)
}

func renderSessionError(_ e: SessionError) -> Int32 {
    let msg: String
    let code: Int32
    switch e {
    case .noSession:
        msg = "refused: no session is running"
        code = 3
    case .alreadyRunning:
        msg = "refused: a session is already running — use `extend` or `end`"
        code = 3
    case .durationTooLong:
        msg = "refused: a session is capped at 7 days"
        code = 64
    case .nonPositiveDuration:
        msg = "refused: the duration must be greater than zero"
        code = 64
    case .indefiniteSession:
        msg = "refused: this session is indefinite (the plain switch) — start a timed session instead"
        code = 3
    case .flagOnNotOwned:
        msg = "refused: lid stay-awake is on but RunClosed does not own it on this boot, so the session could not be ended at its deadline. Turn it off then on (`lid-stay-awake off --operator` then `on`), or start an indefinite session."
        code = 3
    case .preconditionUnknown:
        msg = "refused: B1 invariant — observed prior state is UNKNOWN (pmset -g did not report SleepDisabled)"
        code = 3
    case .notOwned:
        msg = "refused: B2 invariant — we do not own the disablesleep flag on this boot"
        code = 3
    case .flagAlreadyOff:
        msg = "no change: the flag already read off"
        code = 0
    case .backendFailed(let m):
        msg = "backend failed: \(m)"
        code = 5
    }
    FileHandler.err(msg)
    return code
}

func cmdSession(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err(sessionUsage)
        return 64
    }
    let args = Array(rest.dropFirst())

    switch sub {
    case "status":
        // Read-only: no lock, no mutation, no file write. Same stance as
        // `low-battery status`.
        let svc = makeSessionService()
        let now = svc.currentNow()
        let session = svc.load()
        if args.contains("--json") {
            emitJSON([
                "schemaVersion": kSchemaVersion,
                "bootID": now.bootID,
                "session": sessionJSON(session, now: now),
                "ownership": svc.currentOwnership.rawValue,
                "storedSchemaVersion": SessionStore().storedSchemaVersion() as Any? ?? NSNull(),
                "observed": PowerReadback.lidStayAwake().map { $0 ? "on" : "off" } ?? "unknown",
                "rowLabel": session.flatMap { SessionPolicy.rowLabel($0, now: now) } as Any? ?? NSNull(),
            ])
        } else {
            print(sessionHumanLine(session, now: now))
        }
        return 0

    case "start":
        // Refused HERE, before any lock or write: a usage error must not
        // queue behind the guard tick, and must never start a session.
        let duration: TimeInterval?
        switch SessionDuration.parseStartArguments(args) {
        case .success(.timed(let seconds)): duration = seconds
        case .success(.indefinite): duration = nil
        case .failure(.overCap):
            FileHandler.err("refused: a session is capped at 7 days")
            return 64
        case .failure(.usage):
            FileHandler.err(sessionUsage)
            return 64
        }
        // Same lock as `lid-stay-awake on|off`: the session writes the record
        // and the flag, so it must not interleave with a guard tick.
        var svc = makeSessionService()
        // The backstop probe is read BEFORE the lock, not inside it: it is an
        // `SMAppService` XPC round-trip to `smd`, and holding `LidWriteLock`
        // (a blocking flock) across it stalls the app's guard tick and every
        // other CLI command — precisely when a slow `smd` is already the
        // problem. Nothing is lost by reading it first: the rule it feeds is
        // deliberately tolerant to 180 s of heartbeat age, so microseconds of
        // extra staleness cannot change the answer. The `app.lock` probe stays
        // INSIDE, where it must be: the app's quit teardown releases it in this
        // same section, so a start queued behind a teardown must find the app
        // already gone.
        let backstopEnforcing = backstopIsProtecting()
        let locked = LidWriteLock().withLock { () -> Result<SessionService.StartOutcome, SessionError>? in
            // A timed session needs something to end it at its deadline. Two
            // enforcers qualify (ADR 023, amended by ADR 024): the menu-bar app
            // (`app.lock`) or the launchd recovery backstop — and for the
            // backstop, being APPROVED is not enough: it must have PROVEN it
            // runs (a heartbeat on this boot, recent, not a failed run). An
            // approved agent whose program never resolves enforces nothing.
            if duration != nil, !AppLivenessLock().isHeld(),
               !(backstopEnforcing && backstopStillEnforcingLocked()) {
                return nil
            }
            // `start` itself clears a pending low-battery re-arm on success,
            // for the popup and the CLI alike.
            return svc.start(for: duration)
        }
        guard let result = locked else {
            // Built here, outside the lock: `backstopRefusalReason()` re-queries
            // `SMAppService` (an XPC round-trip), and a slow daemon would
            // otherwise hold `LidWriteLock` while the app's guard tick waits.
            FileHandler.err("refused: nothing would end this session at its deadline — RunClosed.app is not running, and \(backstopRefusalReason()). Open RunClosed, or see `runclosed-cli backstop status`.")
            return 3
        }
        switch result {
        case .success(let outcome):
            let now = svc.currentNow()
            var obj = sessionJSON(svc.load(), now: now)
            obj["schemaVersion"] = kSchemaVersion
            obj["bootID"] = now.bootID
            switch outcome {
            case .started: obj["outcome"] = "started"
            case .adoptedRunningFlag: obj["outcome"] = "adoptedRunningFlag"
            }
            emitJSON(obj)
            return 0
        case .failure(let e):
            return renderSessionError(e)
        }
    case "extend":
        var step = SessionDuration.extendStep
        if let raw = args.first {
            guard let parsed = SessionDuration.parse(raw) else {
                FileHandler.err(sessionUsage)
                return 64
            }
            // Same cap, same reason: refuse before the lock.
            guard SessionDuration.isAcceptable(parsed) else {
                FileHandler.err("refused: a session is capped at 7 days")
                return 64
            }
            step = parsed
        }
        var svc = makeSessionService()
        // Read outside the lock for the same reason as `start --for`: it is an
        // XPC round-trip and the answer is age-tolerant by 180 s. `svc.load()`
        // stays inside — that is a record read the lock actually protects.
        let backstopEnforcing = backstopIsProtecting()
        let locked = LidWriteLock().withLock { () -> Result<KeepAwakeSession, SessionError>? in
            // Same refusal as `start --for`, same two enforcers (ADR 024): a new
            // deadline that nothing would enforce must not be reported as
            // "extended" (the app crashed during a timed session). No session on
            // record falls through to `extend`'s own `noSession`.
            if svc.load() != nil, !AppLivenessLock().isHeld(),
               !(backstopEnforcing && backstopStillEnforcingLocked()) {
                return nil
            }
            return svc.extend(by: step)
        }
        guard let result = locked else {
            FileHandler.err("refused: nothing would enforce this session's new deadline — RunClosed.app is not running, and \(backstopRefusalReason()). Open RunClosed, or see `runclosed-cli backstop status`.")
            return 3
        }
        switch result {
        case .success(let session):
            let now = svc.currentNow()
            var obj = sessionJSON(session, now: now)
            obj["schemaVersion"] = kSchemaVersion
            obj["bootID"] = now.bootID
            obj["outcome"] = "extended"
            emitJSON(obj)
            return 0
        case .failure(let e):
            return renderSessionError(e)
        }
    case "end":
        // Same contract as `lid-stay-awake off`: only `--operator` may turn
        // off a flag RunClosed did not set (ADR 021).
        guard args.isEmpty || args == ["--operator"] else {
            FileHandler.err(sessionUsage)
            return 64
        }
        let byOperator = args == ["--operator"]
        var svc = makeSessionService()
        let result = LidWriteLock().withLock { svc.end(byOperator: byOperator) }
        switch result {
        case .success(let outcome):
            emitJSON([
                "schemaVersion": kSchemaVersion,
                "bootID": clock.bootID,
                "action": "end",
                "outcome": outcome.rawValue,
                "error": outcome.failureMessage as Any? ?? NSNull(),
            ])
            if outcome == .flagLeftOn {
                // The record is gone, but B2 kept the flag ON: not ours.
                FileHandler.err("refused: the session ended, but lid stay-awake is still on and RunClosed does not own it, so it was left on. A human can turn it off with `lid-stay-awake off --operator`.")
                return 3
            }
            return outcome.isFailure ? 5 : 0
        case .failure(let e):
            return renderSessionError(e)
        }
    default:
        FileHandler.err(sessionUsage)
        return 64
    }
}

// ── ADR 024 — `recover --backstop` (the LaunchAgent's one command) ──────────

let recoverUsage = """
usage: runclosed recover --backstop

`recover --backstop` is run by the RunClosed recovery LaunchAgent every 60 s.
It takes ONLY protective actions while RunClosed.app is not running: it ends a
session whose deadline passed and releases lid stay-awake on a critical
battery (then lets the Mac sleep). It never turns lid stay-awake ON.

Exit codes: 0 ok / nothing to do, 3 refused by policy, 5 backend failure,
            64 usage, 75 busy (another writer holds the lock — retry next minute)
"""

func cmdRecover(_ rest: [String]) -> Int32 {
    // `--backstop` is MANDATORY. Without it this command would be a bare
    // mutation reachable by anyone; the agent's plist carries the flag, so a
    // hand-edited caller that drops it gets a usage error, not a release.
    guard rest == ["--backstop"] else {
        FileHandler.err(recoverUsage)
        return 64
    }
    return renderRecover(RecoveryBackstopService.live(bootID: clock.bootID))
}

/// The rendering seam: the tests build the same service on fakes and assert
/// the exit code and the JSON shape through THIS function, so what they prove
/// is what the LaunchAgent actually runs.
func renderRecover(_ service: RecoveryBackstopService) -> Int32 {
    var service = service
    let outcome = service.run()
    // The body AND the exit code come from the library, so the tests can
    // assert exactly what this prints.
    let described = RecoveryBackstopService.describe(outcome, bootID: clock.bootID)
    emitJSON(described.json)
    // launchd no longer names a log file (a plist inside a signed bundle is
    // fixed bytes, so any path there belongs to the build account). The agent
    // writes its own one-line trace under the home of the user it runs as.
    RunClosedBackstopDescriptor.appendAgentLog(
        "\(ISO8601DateFormatter().string(from: Date())) "
        + "recover --backstop exit=\(described.exitCode) outcome=\(outcome.rawValue)")
    return described.exitCode
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

// ── ADR 026 — lid-close actions ─────────────────────────────────────────────

let lidCloseUsage = """
usage: runclosed lid-close status [--json]        (read-only)
       runclosed lid-close simulate [--session on|off|paused]
                 [--lid closed|open|unknown] [--external-display yes|no|unknown]
                 [--enabled on|off] [--mute on|off] [--pause-apps on|off]

`simulate` is a pure decision on injected values: it never reads the audio
device, never signals a process, and never writes the journal.
"""

/// Build the read-only service the CLI uses. The audio and process backends are
/// the LIVE ones, but `status` only reads: `evaluate` and `journal.load` mutate
/// nothing. There is deliberately no CLI command that mutes or pauses — the
/// actions belong to the session tick, and a stray command could leave a Mac
/// mute with no session to end it.
func makeLidCloseService() -> LidCloseActionService {
    LidCloseActionService(
        journal: LidCloseActionJournal(),
        auditLog: LidCloseActionAuditLog(),
        audio: CoreAudioOutputBackend(),
        processes: LibprocPauseBackend(bootID: clock.bootID),
        bootID: clock.bootID)
}

func cmdLidClose(_ rest: [String]) -> Int32 {
    guard let sub = rest.first else {
        FileHandler.err(lidCloseUsage)
        return 64
    }
    switch sub {
    case "status":
        let args = Array(rest.dropFirst())
        guard args.isEmpty || args == ["--json"] else {
            FileHandler.err(lidCloseUsage)
            return 64
        }
        let session = SessionStore().load()
        let settings = LidCloseActionSettingsStore.load()
        let svc = makeLidCloseService()
        let e = svc.evaluate(
            sessionActive: LidCloseActionPolicy.sessionIsActive(session),
            lidClosed: ClamshellReadback.lidClosed(),
            externalDisplayConnected: ClamshellReadback.externalDisplayConnected(),
            settings: settings)
        let journal = e.journalBefore
        // A damaged journal is NOT a clean slate: report it and refuse to claim
        // "applied: false" over a recovery that may still be owed.
        let journalCorrupt = LidCloseActionJournal().isCorrupt
        let entries = LidCloseActionAuditLog().load()
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "bootID": clock.bootID,
            "mode": "status (read-only)",
            "settings": [
                "enabled": settings.enabled,
                "muteAudio": settings.muteAudio,
                "pauseApps": settings.pauseApps,
                "pausedApps": settings.pausedApps,
            ],
            "conditions": [
                "sessionActive": LidCloseActionPolicy.sessionIsActive(session),
                "sessionPaused": session?.isPaused as Any? ?? false,
                "lidClosed": e.input.lidClosed as Any? ?? NSNull(),
                "externalDisplayConnected": e.input.externalDisplayConnected as Any? ?? NSNull(),
            ],
            "decision": [
                "action": e.decision.action.rawValue,
                "reason": e.decision.reason.rawValue,
                "muteAudio": e.decision.muteAudio,
                "pauseApps": e.decision.pauseApps,
                "appNames": e.decision.appNames,
            ],
            "journal": [
                "applied": !journal.isEmpty,
                "sessionID": journal.sessionID?.uuidString as Any? ?? NSNull(),
                "startedAt": journal.startedAt as Any? ?? NSNull(),
                "audioDeviceUID": journal.audio?.deviceUID as Any? ?? NSNull(),
                "audioWasMuted": journal.audio?.wasMuted as Any? ?? NSNull(),
                "stoppedPids": journal.stopped.map { Int($0.pid) },
                "unverifiedPids": journal.unverified.map { Int($0.pid) },
                // An audio obligation that is not a live effect: the device was
                // muted by RunClosed, became unreachable and has not come back.
                // Without this the operator sees `applied: false` and could not
                // tell that a restore is still owed (gate finding, `Status
                // reports success while audio restoration remains unresolved`).
                "unverifiedAudioDeviceUIDs": journal.unverifiedAudio.map { $0.deviceUID },
                "unverifiedAudioWasMuted": journal.unverifiedAudio.map { $0.wasMuted },
                "readable": !journalCorrupt,
            ],
            "lastAction": entries.last.map { entry -> [String: Any] in
                [
                    "ts": entry.ts,
                    "outcome": entry.outcome,
                    "reason": entry.reason,
                ]
            } as Any? ?? NSNull(),
        ])
        // Exit 3 when ANYTHING is still owed: a process to verify, or an audio
        // restore to complete. Reporting 0 over an unresolved obligation is the
        // "healthy" signal this lot exists to avoid.
        let unresolved = !journal.unverified.isEmpty || !journal.unverifiedAudio.isEmpty
            || journalCorrupt
        return unresolved ? 3 : 0

    case "simulate":
        let args = Array(rest.dropFirst())
        var sessionActive = true
        var lidClosed: Bool? = true
        var external: Bool? = false
        var settings = LidCloseActionSettings(enabled: true)
        var applied = false
        var i = 0
        func onOff(_ s: String) -> Bool? {
            switch s {
            case "on", "yes", "true": return true
            case "off", "no", "false": return false
            default: return nil
            }
        }
        while i < args.count {
            switch args[i] {
            case "--session":
                i += 1
                guard i < args.count else { FileHandler.err(lidCloseUsage); return 64 }
                switch args[i] {
                case "on": sessionActive = true
                case "off": sessionActive = false
                case "paused": sessionActive = false
                default: FileHandler.err(lidCloseUsage); return 64
                }
            case "--lid":
                i += 1
                guard i < args.count else { FileHandler.err(lidCloseUsage); return 64 }
                switch args[i] {
                case "closed": lidClosed = true
                case "open": lidClosed = false
                case "unknown": lidClosed = nil
                default: FileHandler.err(lidCloseUsage); return 64
                }
            case "--external-display":
                i += 1
                guard i < args.count else { FileHandler.err(lidCloseUsage); return 64 }
                switch args[i] {
                case "yes", "connected", "true": external = true
                case "no", "none", "false": external = false
                case "unknown": external = nil
                default: FileHandler.err(lidCloseUsage); return 64
                }
            case "--enabled", "--mute", "--pause-apps":
                let key = args[i]
                i += 1
                guard i < args.count, let v = onOff(args[i]) else {
                    FileHandler.err(lidCloseUsage)
                    return 64
                }
                switch key {
                case "--enabled": settings.enabled = v
                case "--mute": settings.muteAudio = v
                default: settings.pauseApps = v
                }
            case "--already-applied":
                applied = true
            default:
                FileHandler.err(lidCloseUsage)
                return 64
            }
            i += 1
        }
        let input = LidCloseActionPolicy.Input(
            sessionActive: sessionActive, lidClosed: lidClosed,
            externalDisplayConnected: external, settings: settings)
        let decision = LidCloseActionPolicy.decide(input, currentlyApplied: applied)
        emitJSON([
            "schemaVersion": kSchemaVersion,
            "mode": "simulate (dry-run, pure decision, nothing mutated)",
            "input": [
                "sessionActive": sessionActive,
                "lidClosed": lidClosed as Any? ?? NSNull(),
                "externalDisplayConnected": external as Any? ?? NSNull(),
                "enabled": settings.enabled,
                "muteAudio": settings.muteAudio,
                "pauseApps": settings.pauseApps,
            ],
            "conditionsHold": LidCloseActionPolicy.conditionsHold(input),
            "currentlyApplied": applied,
            "decision": [
                "action": decision.action.rawValue,
                "reason": decision.reason.rawValue,
                "muteAudio": decision.muteAudio,
                "pauseApps": decision.pauseApps,
                "appNames": decision.appNames,
            ],
        ])
        return 0

    default:
        FileHandler.err(lidCloseUsage)
        return 64
    }
}


// ── dispatch ─────────────────────────────────────────────────────────────────
let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else {
    FileHandler.err("usage: runclosed <status|displays|doctor|run|restore|disable|enable|lid-stay-awake|login-item|helper|low-battery|thermal|lid-close|session|recover|backstop> [...]")
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
case "session":  exit(cmdSession(rest))
case "recover":  exit(cmdRecover(rest))
case "backstop": exit(cmdBackstop(rest))
case "thermal":  exit(cmdThermal(rest))
case "lid-close": exit(cmdLidClose(rest))
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
