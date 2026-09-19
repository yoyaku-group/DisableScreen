import Foundation

/// Read-only power/lid state (no mutation). Mirrors the Python tri-state (A10):
/// nil = unknown, never silently OFF.
public enum PowerReadback {
    /// disablesleep flag from `pmset -g`. true/false, or nil if undeterminable.
    public static func lidStayAwake() -> Bool? {
        guard let out = run("/usr/bin/pmset", ["-g"]) else { return nil }
        return parseLidStayAwake(out)
    }

    /// Pure parser — unit-tested. `pmset -g` separates key and value with one
    /// or more TABS (` SleepDisabled\t\t1`); the original `split(separator: " ")`
    /// never matched, so the readback reported `false` even while the flag was
    /// ON, and every lid toggle looked broken (live finding 2026-09-20).
    /// Split on any whitespace run instead.
    static func parseLidStayAwake(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("SleepDisabled") else { continue }
            let fields = s.split(whereSeparator: \.isWhitespace)
            guard let value = fields.last else { return nil }
            return value == "1"
        }
        return nil  // key absent → unknown, not false
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
