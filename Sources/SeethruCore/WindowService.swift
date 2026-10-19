import AppKit
import CoreGraphics

public protocol WindowListing: Sendable {
    /// Normal, on-screen windows, front to back.
    func snapshot() -> [WindowInfo]
    /// True while the window still exists anywhere (even when moved off-screen by a backend).
    func windowExists(_ id: WindowID) -> Bool
}

public struct CGWindowService: WindowListing {
    public let ownPID: Int32
    public init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) { self.ownPID = ownPID }

    public func snapshot() -> [WindowInfo] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let raw = WindowFilter.filter(rows.compactMap(WindowFilter.parse), ownPID: ownPID)
        var bundleIDs: [Int32: String?] = [:]
        return raw.map { r in
            let bundle: String?
            if let cached = bundleIDs[r.pid] { bundle = cached } else {
                bundle = NSRunningApplication(processIdentifier: r.pid)?.bundleIdentifier
                bundleIDs[r.pid] = bundle
            }
            return WindowInfo(id: WindowID(pid: r.pid, number: r.number), ownerName: r.ownerName, bundleID: bundle,
                              title: r.title, bounds: r.bounds, alpha: r.alpha)
        }
    }

    public func windowExists(_ id: WindowID) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id.number)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id.number }
    }
}
