import XCTest
@testable import RunClosedCore
@testable import RunClosedPersistence

/// The generic audit sink extracted from `LowBatteryAuditLog` (ADR 025). Two
/// things must hold: the mechanics are shared (so a third trail cannot drift),
/// and the battery file keeps its exact on-disk format.
final class JSONLAuditLogTests: XCTestCase {

    private func tempURL(_ name: String = "audit.jsonl") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runclosed-jsonl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    private struct Entry: Codable, Equatable {
        var b: Int
        var a: String
    }

    func testAppendWritesOneSortedJSONObjectPerLine() throws {
        let url = tempURL()
        let log = JSONLAuditLog(url: url)
        log.append(Entry(b: 2, a: "two"))
        log.append(Entry(b: 1, a: "one"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        // Sorted keys: `a` before `b`, every time.
        XCTAssertEqual(String(lines[0]), #"{"a":"two","b":2}"#)
        XCTAssertEqual(String(lines[1]), #"{"a":"one","b":1}"#)
    }

    func testLoadSkipsUnparseableLines() throws {
        let url = tempURL()
        let log = JSONLAuditLog(url: url)
        log.append(Entry(b: 1, a: "good"))
        // A truncated line, as a short write leaves behind.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"a":"trunc","#.utf8))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        log.append(Entry(b: 2, a: "also good"))
        XCTAssertEqual(log.load(Entry.self), [Entry(b: 1, a: "good"),
                                              Entry(b: 2, a: "also good")])
    }

    func testLoadOnAMissingFileIsEmpty() {
        XCTAssertTrue(JSONLAuditLog(url: tempURL()).load(Entry.self).isEmpty)
    }

    func testFileModeIsOwnerOnly() throws {
        let url = tempURL()
        JSONLAuditLog(url: url).append(Entry(b: 1, a: "x"))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// The extraction must be INVISIBLE in the battery trail's file: same keys,
    /// same one-object-per-line layout, same sorted order. A change here would
    /// silently break every existing reader of `low_battery_audit.jsonl`.
    func testTheBatteryLogFormatIsUnchangedByTheExtraction() throws {
        let url = tempURL("low_battery_audit.jsonl")
        let log = LowBatteryAuditLog(url: url)
        log.append(.init(ts: "2026-11-07T10:00:00Z", bootID: "A", reason: "criticalOwned",
                         outcome: "released", chargePercent: 9, minutesRemaining: 8,
                         recordBootID: "A", error: nil, sleepRC: 0))
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["reason"] as? String, "criticalOwned")
        XCTAssertEqual(decoded["outcome"] as? String, "released")
        XCTAssertEqual(decoded["chargePercent"] as? Int, 9)
        XCTAssertEqual(decoded["sleepRC"] as? Int, 0)
        XCTAssertEqual(decoded["bootID"] as? String, "A")
        // `nil` optionals are OMITTED, exactly as `JSONEncoder` default does —
        // an explicit `"error":null` would be a format change.
        XCTAssertNil(decoded["error"])
        // Round-trips through the type's own reader.
        XCTAssertEqual(log.load().count, 1)
        XCTAssertEqual(log.load().first?.reason, "criticalOwned")
    }

    func testTheThermalLogWritesItsOwnFile() {
        let thermal = ThermalAuditLog()
        XCTAssertEqual(thermal.url.lastPathComponent, "thermal_audit.jsonl")
        XCTAssertNotEqual(thermal.url, LowBatteryAuditLog().url,
                          "heat and battery actions are separate trails")
    }

    /// One line per ACTION, and the JSON shape carries what a forensic read
    /// needs: what the machine's state was, and why the guard refused.
    func testThermalEntryRoundTrip() {
        let url = tempURL("thermal_audit.jsonl")
        let log = ThermalAuditLog(url: url)
        log.append(.init(ts: "2026-11-07T10:00:00Z", bootID: "A", reason: "notOwned",
                         outcome: "releaseRefused", thermalState: "critical", lid: "closed",
                         externalDisplay: "none", ownership: "notOwned",
                         recordBootID: "A", error: "not owned on this boot (B2)", sleepRC: nil))
        let entries = log.load()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.thermalState, "critical")
        XCTAssertEqual(entries.first?.lid, "closed")
        XCTAssertEqual(entries.first?.externalDisplay, "none")
        XCTAssertEqual(entries.first?.outcome, "releaseRefused")
    }
}
