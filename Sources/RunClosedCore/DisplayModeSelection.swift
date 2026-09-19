import Foundation

/// Pure selection logic for the resolution dropdown. The MacSystem layer feeds
/// raw CoreGraphics modes; tests feed literals — this file has no device
/// dependency (ADR 002/010).
public enum DisplayModeSelection {

    public struct Mode: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var refresh: Double

        public init(width: Int, height: Int, refresh: Double) {
            self.width = width
            self.height = height
            self.refresh = refresh
        }

        /// "3456x2234  @120Hz" — refresh omitted when the backend reports 0
        /// (some software/virtual modes do), mirroring the Python label.
        public var label: String {
            refresh > 0 ? "\(width)x\(height)  @\(Int(refresh))Hz" : "\(width)x\(height)"
        }
    }

    /// Dedupe by (width, height) keeping the highest refresh, then sort
    /// largest-first. Deterministic — the popup's item index maps 1:1 onto
    /// this list, so populating and selecting must use the same output.
    public static func normalize(_ modes: [Mode]) -> [Mode] {
        var best: [Pair: Mode] = [:]
        for m in modes where m.width > 0 && m.height > 0 {
            let key = Pair(width: m.width, height: m.height)
            if let current = best[key], current.refresh >= m.refresh { continue }
            best[key] = m
        }
        return best.values.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            return a.refresh > b.refresh
        }
    }

    /// Highest-refresh mode matching the requested (width, height), or nil
    /// when the list has no such mode.
    public static func best(in modes: [Mode], width: Int, height: Int) -> Mode? {
        modes.filter { $0.width == width && $0.height == height }
            .max { $0.refresh < $1.refresh }
    }

    /// Index of the first mode matching (width, height) in a normalized list,
    /// or nil when the current mode is absent from the list.
    public static func index(in modes: [Mode], width: Int, height: Int) -> Int? {
        modes.firstIndex { $0.width == width && $0.height == height }
    }

    private struct Pair: Hashable {
        let width: Int
        let height: Int
    }
}
