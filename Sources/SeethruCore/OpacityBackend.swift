import Foundation

public enum PermissionKind: String, Sendable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
}

public enum BackendError: Error, Equatable, LocalizedError, Sendable {
    case permissionMissing(PermissionKind)
    case windowNotFound
    case cannotHideOriginal
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionMissing(let p):
            "\(p.rawValue) permission is required."
        case .windowNotFound:
            "The window is no longer available."
        case .cannotHideOriginal:
            "This app\u{2019}s window cannot be moved out of sight (macOS keeps too much of it on screen), so click-through and always-on-top are not available for it."
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

/// Changes how see-through another app's window is. The implementation is `MirrorBackend`.
@MainActor
public protocol OpacityBackend: AnyObject {
    var capabilities: BackendCapabilities { get }
    /// Which permissions this backend needs before `setOpacity` can work.
    var requiredPermissions: [PermissionKind] { get }
    /// Called when a backend loses a window on its own (closed, stream died). The engine drops its state.
    var onWindowLost: (@MainActor (WindowID, BackendError?) -> Void)? { get set }

    func setOpacity(_ window: WindowInfo, value: Double, options: WindowOptions) async throws
    func restore(_ id: WindowID)
    func restoreAll()
}
