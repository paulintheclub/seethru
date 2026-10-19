import Foundation

public enum BackendKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case mirror
    case skyLight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mirror: "Mirror (recommended)"
        case .skyLight: "SkyLight (experimental)"
        }
    }
}

public enum PermissionKind: String, Sendable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
}

public enum BackendError: Error, Equatable, LocalizedError, Sendable {
    case symbolsMissing
    /// The window server accepted the call (rc 0) but the window did not change.
    case refusedByWindowServer
    case permissionMissing(PermissionKind)
    case windowNotFound
    case cannotHideOriginal
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .symbolsMissing:
            "This macOS version does not expose the private window API Seethru needs."
        case .refusedByWindowServer:
            "macOS ignored the request. Changing another app's window opacity directly is blocked with SIP enabled; use the Mirror backend."
        case .permissionMissing(let p):
            "\(p.rawValue) permission is required."
        case .windowNotFound:
            "The window is no longer available."
        case .cannotHideOriginal:
            "This app\u{2019}s window cannot be moved out of sight (macOS keeps too much of it on screen), so a see-through copy would show a double image."
        case .captureFailed(let m):
            "Screen capture failed: \(m)"
        }
    }
}

public struct BackendCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let alwaysOnTop = BackendCapabilities(rawValue: 1 << 0)
    public static let clickThrough = BackendCapabilities(rawValue: 1 << 1)
}

/// Changes how see-through another app's window is. Implementations: `MirrorBackend`, `SkyLightBackend`.
@MainActor
public protocol OpacityBackend: AnyObject {
    var kind: BackendKind { get }
    var capabilities: BackendCapabilities { get }
    /// Which permissions this backend needs before `setOpacity` can work.
    var requiredPermissions: [PermissionKind] { get }
    /// Called when a backend loses a window on its own (closed, stream died). The engine drops its state.
    var onWindowLost: (@MainActor (WindowID, BackendError?) -> Void)? { get set }

    func setOpacity(_ window: WindowInfo, value: Double, options: WindowOptions) async throws
    func restore(_ id: WindowID)
    func restoreAll()
}
