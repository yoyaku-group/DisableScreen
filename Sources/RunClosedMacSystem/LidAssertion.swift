import Foundation
import RunClosedCore

/// Backend protocol for the single `pmset disablesleep` mutation primitive.
///
/// `setEnabled(true)` → `pmset -a disablesleep 1`  (system keeps awake on lid close)
/// `setEnabled(false)` → `pmset -a disablesleep 0` (standard sleep posture restored)
///
/// The wrapper intentionally goes through the public `pmset(1)` CLI rather than
/// poking the private IOPMSleepPrefs API: `pmset` does its own validation, its
/// own persistence, and its own audit logging. The downsides (a fork+exec, plus
/// the readback round-trip) are negligible compared to the correctness gain.
public protocol LidAssertion: Sendable {
    /// Apply the request and return a typed OperationResult.
    /// - `.verified`  if the write succeeded AND `pmset -g` confirms the new state.
    /// - `.failed`    if either the write or the readback disagreed.
    /// - `.unknown`   if we could not communicate with `pmset` at all.
    mutating func setEnabled(_ enabled: Bool) -> OperationResult
}

// MARK: — Real backend (pmset subprocess)

/// Live backend wrapping `pmset -a disablesleep <0|1>` + readback via
/// `pmset -g`. Each call is synchronous (subprocess fork+exec + readback
/// roundtrip); it is NOT meant to be called from the main thread for
/// interactive paths — the CLI is already sequential so the cost is paid by
/// the user's terminal.
public struct PMSetLidAssertion: LidAssertion {

    public init() {}

    public mutating func setEnabled(_ enabled: Bool) -> OperationResult {
        let desiredValue = enabled ? "1" : "0"
        // Write phase — capture both rc AND combined stdout/stderr output
        // (pmset's exit code is unreliable on macOS: e.g. it exits 0 with
        // "must be run as root" when called unprivileged — the readback is
        // the only authoritative signal).
        let write = runPmsetWrite(value: desiredValue)
        if write.rc != 0 {
            return OperationResult(
                requestID: UUID().uuidString,
                action: .sleepAll,
                state: .failed,
                nativeRC: Int(write.rc),
                readbackOK: false,
                error: write.output ?? "pmset -a disablesleep \(desiredValue) returned rc=\(write.rc)"
            )
        }
        // Readback phase — this is the authoritative truth, regardless of
        // what rc + pmset output said.
        let readback = PowerReadback.lidStayAwake()
        guard let observed = readback else {
            return OperationResult(
                requestID: UUID().uuidString,
                action: .sleepAll,
                state: .failed,
                nativeRC: Int(write.rc),
                readbackOK: false,
                error: (write.output ?? "") +
                    " | readback: pmset -g did not report SleepDisabled"
            )
        }
        let expected = enabled
        let verified = (observed == expected)
        return OperationResult(
            requestID: UUID().uuidString,
            action: .sleepAll,
            state: verified ? .verified : .failed,
            nativeRC: Int(write.rc),
            readbackOK: verified,
            error: verified ? nil : composeReadbackError(
                writeOutput: write.output,
                observed: observed,
                expected: expected
            )
        )
    }

    // MARK: — Plumbing

    private func runPmsetWrite(value: String) -> (rc: Int32, output: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", value]
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, "Process fork failed: \(error)")
        }
        // pmset's diagnostic messages (e.g. "'pmset' must be run as root...")
        // are written to stderr when stderr is a tty — but when stderr is
        // captured via Pipe (as we do here), pmset routes them to stdout
        // instead. Capture both and merge into a single output buffer.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        var parts: [String] = []
        if let s = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            parts.append(s)
        }
        if let s = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            parts.append(s)
        }
        let merged = parts.isEmpty ? nil : parts.joined(separator: " | ")
        return (p.terminationStatus, merged)
    }

    /// Build a user-actionable error string that includes both the pmset
    /// warning (if any) AND the concrete readback contradiction. Often the
    /// pmset warning will be the more useful hint (e.g. "must be run as
    /// root") — surfacing it first saves the user one round-trip.
    private func composeReadbackError(
        writeOutput: String?,
        observed: Bool,
        expected: Bool
    ) -> String {
        var parts: [String] = []
        if let w = writeOutput { parts.append(w) }
        parts.append("readback: observed=\(observed), expected=\(expected)")
        return parts.joined(separator: " | ")
    }
}

// MARK: — Convenience factory for production wiring

public enum LidAssertions {
    /// Real production assertion. Touches the user's machine on invocation —
    /// callers are expected to have gated it through `LidMutationService`
    /// (B1: known prior state; B2: we own it from this boot).
    public static func live() -> any LidAssertion {
        return PMSetLidAssertion()
    }
}
