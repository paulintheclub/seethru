import CoreGraphics
import Foundation

/// Stable identity for a window: owner pid + window server number.
public struct WindowID: Hashable, Codable, Sendable {
    public let pid: Int32
    public let number: UInt32
    public init(pid: Int32, number: UInt32) {
        self.pid = pid
        self.number = number
    }
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: WindowID
    public var ownerName: String
    public var bundleID: String?
    public var title: String
    public var bounds: CGRect
    public var alpha: Double

    public init(id: WindowID, ownerName: String, bundleID: String? = nil, title: String = "",
                bounds: CGRect = .zero, alpha: Double = 1) {
        self.id = id
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.title = title
        self.bounds = bounds
        self.alpha = alpha
    }

    public var displayTitle: String { title.isEmpty ? "Untitled window" : title }
}

public struct AppGroup: Identifiable, Hashable, Sendable {
    public let id: Int32 // pid
    public var bundleID: String?
    public var name: String
    public var windows: [WindowInfo]

    public init(id: Int32, bundleID: String?, name: String, windows: [WindowInfo]) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.windows = windows
    }
}

/// Per-window extras a backend may support.
public struct WindowOptions: Hashable, Codable, Sendable {
    public var alwaysOnTop: Bool
    public var clickThrough: Bool
    public init(alwaysOnTop: Bool = false, clickThrough: Bool = false) {
        self.alwaysOnTop = alwaysOnTop
        self.clickThrough = clickThrough
    }
    public static let none = WindowOptions()
}
