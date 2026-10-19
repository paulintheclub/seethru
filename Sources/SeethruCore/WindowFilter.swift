import CoreGraphics
import Foundation

/// One row of `CGWindowListCopyWindowInfo`, parsed. Pure data so filtering can be unit-tested.
public struct RawWindow: Equatable, Sendable {
    public var number: UInt32
    public var pid: Int32
    public var ownerName: String
    public var title: String
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public var isOnScreen: Bool

    public init(number: UInt32, pid: Int32, ownerName: String, title: String = "", layer: Int = 0,
                bounds: CGRect, alpha: Double = 1, isOnScreen: Bool = true) {
        self.number = number
        self.pid = pid
        self.ownerName = ownerName
        self.title = title
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

public enum WindowFilter {
    /// System owners that publish layer-0 windows which are not real app windows.
    public static let systemOwners: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center", "Spotlight"]

    public static func parse(_ dict: [String: Any]) -> RawWindow? {
        guard let number = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return RawWindow(
            number: number,
            pid: pid,
            ownerName: dict[kCGWindowOwnerName as String] as? String ?? "",
            title: dict[kCGWindowName as String] as? String ?? "",
            layer: layer,
            bounds: bounds,
            alpha: (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            isOnScreen: (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        )
    }

    /// Normal windows only: layer 0, on-screen, not tiny, not ours, not a system helper.
    public static func filter(_ raw: [RawWindow], ownPID: Int32, minSize: CGFloat = 80) -> [RawWindow] {
        raw.filter {
            $0.layer == 0
                && $0.isOnScreen
                && $0.pid != ownPID
                && $0.bounds.width >= minSize
                && $0.bounds.height >= minSize
                && !systemOwners.contains($0.ownerName)
        }
    }

    /// Groups windows by owning app (pid), apps sorted by name, windows keep their input (z) order.
    public static func group(_ windows: [WindowInfo]) -> [AppGroup] {
        var order: [Int32] = []
        var buckets: [Int32: [WindowInfo]] = [:]
        for w in windows {
            if buckets[w.id.pid] == nil { order.append(w.id.pid) }
            buckets[w.id.pid, default: []].append(w)
        }
        return order
            .map { pid -> AppGroup in
                let ws = buckets[pid]!
                return AppGroup(id: pid, bundleID: ws[0].bundleID, name: ws[0].ownerName, windows: ws)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Top-most window of `pid`. `windows` must be ordered front to back (as CGWindowList returns them).
    public static func frontmostWindow(of pid: Int32, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.id.pid == pid }
    }
}
