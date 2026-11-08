import CoreGraphics
import Foundation

enum WindowGeometry {
    struct State: Equatable {
        var bounds: CGRect
        var onScreen: Bool
    }

    /// Current frame (CG coordinates) and on-screen flag, or nil when the window no longer exists.
    /// A hidden or minimized window is not in the on-screen list but still exists, so fall back to the full list
    /// before concluding that it is gone.
    static func state(of number: UInt32) -> State? {
        if let s = parse(CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)), number) { return s }
        return parse(CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID), number)
    }

    private static func parse(_ list: CFArray?, _ number: UInt32) -> State? {
        let rows = list as? [[String: Any]] ?? []
        guard let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }),
              let dict = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
        return State(bounds: bounds, onScreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }

    struct Entry {
        let number: UInt32
        let pid: Int32
        let layer: Int
        let bounds: CGRect
        let alpha: Double
    }

    /// Every on-screen window, front to back, with a lookup by window number. One call serves all sessions.
    struct Snapshot {
        let entries: [Entry]
        let index: [UInt32: Int]
    }

    static func snapshot() -> Snapshot {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var entries: [Entry] = []
        entries.reserveCapacity(rows.count)
        for row in rows {
            guard let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            entries.append(Entry(number: number,
                                 pid: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                                 layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                 bounds: bounds,
                                 alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1))
        }
        var index: [UInt32: Int] = [:]
        for (i, e) in entries.enumerated() { index[e.number] = i }
        return Snapshot(entries: entries, index: index)
    }
}
