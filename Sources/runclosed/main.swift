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

// ── dispatch ─────────────────────────────────────────────────────────────────
let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else {
    FileHandler.err("usage: runclosed <status|displays|doctor|run|restore> [...]")
    exit(64)
}
let rest = Array(args.dropFirst())

switch sub {
case "status":   cmdStatus()
case "displays": cmdDisplays()
case "doctor":   cmdDoctor()
case "run":      exit(cmdRun(rest))
case "restore":
    // G3 stub — restore --owned must verify the system before any change; that
    // logic lands with the session-owner service. It changes nothing today.
    FileHandler.err("restore --owned: not implemented in this tranche (G3). No changes made.")
    exit(0)
default:
    FileHandler.err("unknown command: \(sub)")
    exit(64)
}
