import CoreGraphics
import Foundation
import PrivateAPI

/// Direct alpha via SkyLight. On stock macOS (SIP on) the window server ignores this for foreign
/// windows (see docs/FEASIBILITY.md), so this backend verifies by read-back and fails loudly.
@MainActor
public final class SkyLightBackend: OpacityBackend {
    public let kind = BackendKind.skyLight
    public let capabilities: BackendCapabilities = []
    public let requiredPermissions: [PermissionKind] = []
    public var onWindowLost: (@MainActor (WindowID, BackendError?) -> Void)?

    private let api: any WindowAlphaAPI
    private var touched: Set<WindowID> = []

    public init(api: any WindowAlphaAPI = SkyLightAlphaAPI()) { self.api = api }

    public func setOpacity(_ window: WindowInfo, value: Double, options: WindowOptions) async throws {
        guard api.isAvailable else { throw BackendError.symbolsMissing }
        guard api.setAlpha(windowNumber: window.id.number, alpha: Float(value)) != nil else { throw BackendError.symbolsMissing }
        touched.insert(window.id)
        try await Task.sleep(nanoseconds: 80_000_000)
        guard let actual = Self.readAlpha(window.id.number) else { throw BackendError.windowNotFound }
        if abs(actual - value) > 0.02 { throw BackendError.refusedByWindowServer }
    }

    public func restore(_ id: WindowID) {
        _ = api.setAlpha(windowNumber: id.number, alpha: 1)
        touched.remove(id)
    }

    public func restoreAll() {
        for id in touched { _ = api.setAlpha(windowNumber: id.number, alpha: 1) }
        touched.removeAll()
    }

    static func readAlpha(_ number: UInt32) -> Double? {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]] ?? []
        return rows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }
            .flatMap { ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue }
    }
}
