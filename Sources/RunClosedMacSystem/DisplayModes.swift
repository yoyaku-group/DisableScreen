import Foundation
import CoreGraphics
import RunClosedCore

/// Live display-mode surface (CoreGraphics, public API). Read is used by the
/// popup to populate the resolution dropdown; `set` is the A05-style typed
/// mutation — the native call plus a read-back of the observable outcome,
/// never "rc == 0 so it worked".
public enum DisplayModes {

    /// Deduped, largest-first list of usable modes for one display.
    public static func available(displayID: UInt32) -> [DisplayModeSelection.Mode] {
        guard let raw = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return []
        }
        let modes: [DisplayModeSelection.Mode] = raw.map { m in
            DisplayModeSelection.Mode(width: m.width, height: m.height, refresh: m.refreshRate)
        }
        return DisplayModeSelection.normalize(modes)
    }

    /// Current mode as (width, height) pixels, or nil when unreadable.
    public static func current(displayID: UInt32) -> (width: Int, height: Int)? {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (m.width, m.height)
    }

    /// Human label of the current mode ("3456x2234"), or "-" when unreadable.
    public static func currentLabel(displayID: UInt32) -> String {
        guard let c = current(displayID: displayID) else { return "-" }
        return "\(c.width)x\(c.height)"
    }

    /// Apply the highest-refresh mode matching (width, height) and verify the
    /// observable outcome. `ok` is only true when the read-back matches.
    public static func set(displayID: UInt32, width: Int, height: Int) -> OperationResult {
        let modes = available(displayID: displayID)
        guard let target = DisplayModeSelection.best(in: modes, width: width, height: height) else {
            return OperationResult(
                requestID: UUID().uuidString,
                action: .resolution,
                state: .failed,
                nativeRC: nil,
                readbackOK: false,
                error: "no matching mode \(width)x\(height)"
            )
        }

        // Find the raw CGDisplayMode matching the chosen (w, h, refresh),
        // falling back to any mode with the same geometry.
        guard let raw = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return OperationResult(
                requestID: UUID().uuidString,
                action: .resolution,
                state: .failed,
                nativeRC: nil,
                readbackOK: false,
                error: "CGDisplayCopyAllDisplayModes unavailable"
            )
        }
        var exact: CGDisplayMode?
        var geometryMatch: CGDisplayMode?
        for m in raw {
            let sameGeometry = (m.width == target.width && m.height == target.height)
            if sameGeometry {
                if geometryMatch == nil { geometryMatch = m }
                if m.refreshRate == target.refresh { exact = m; break }
            }
        }
        guard let mode = exact ?? geometryMatch else {
            return OperationResult(
                requestID: UUID().uuidString,
                action: .resolution,
                state: .failed,
                nativeRC: nil,
                readbackOK: false,
                error: "no raw CGDisplayMode for \(target.label)"
            )
        }

        let rc: CGError = CGDisplaySetDisplayMode(displayID, mode, nil)
        if rc != CGError.success {
            return OperationResult(
                requestID: UUID().uuidString,
                action: .resolution,
                state: .failed,
                nativeRC: Int(rc.rawValue),
                readbackOK: false,
                error: "CGDisplaySetDisplayMode rc=\(rc.rawValue)"
            )
        }
        let readback = current(displayID: displayID)
        let ok = readback?.width == width && readback?.height == height
        let observedLabel = readback.map { "\($0.width)x\($0.height)" } ?? "-"
        return OperationResult(
            requestID: UUID().uuidString,
            action: .resolution,
            state: ok ? .verified : .failed,
            nativeRC: 0,
            readbackOK: ok,
            error: ok ? nil : "readback: \(observedLabel), expected \(width)x\(height)"
        )
    }
}
