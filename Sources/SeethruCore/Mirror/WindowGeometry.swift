import CoreGraphics
import Foundation

enum WindowGeometry {
    struct State: Equatable {
        var bounds: CGRect
        var onScreen: Bool
    }

    /// Current frame (CG coordinates) and on-screen flag, or nil when the window no longer exists.
    static func state(of number: UInt32) -> State? {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]] ?? []
        guard let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }),
              let dict = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
        return State(bounds: bounds, onScreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }

    /// On-screen window numbers, front to back.
    static func zOrder() -> [UInt32] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }
}
