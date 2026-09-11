import Foundation

/// Read-only power/lid state (no mutation). Mirrors the Python tri-state (A10):
/// nil = unknown, never silently OFF.
public enum PowerReadback {
    /// disablesleep flag from `pmset -g`. true/false, or nil if undeterminable.
    public static func lidStayAwake() -> Bool? {
        guard let out = run("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("SleepDisabled") {
                return s.split(separator: " ").last == "1"
            }
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
