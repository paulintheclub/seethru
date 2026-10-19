import CoreGraphics
import Foundation

/// Result of a private window-server call. A zero return code is NOT proof the
/// window changed: on stock macOS (SIP on) SkyLight accepts alpha calls for
/// foreign windows and silently ignores them. Callers must read the value back.
public protocol WindowAlphaAPI: Sendable {
    var isAvailable: Bool { get }
    /// Returns the raw CGError (0 = accepted), or nil when the symbol is missing.
    func setAlpha(windowNumber: UInt32, alpha: Float) -> Int32?
}

/// Resolves SkyLight symbols at runtime with `dlopen`/`dlsym` so a missing
/// symbol after a macOS update degrades to "unavailable" instead of a crash.
public struct SkyLightAlphaAPI: WindowAlphaAPI {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetAlpha = @convention(c) (Int32, UInt32, Float) -> Int32

    private let mainConnection: MainConnection?
    private let setWindowAlpha: SetAlpha?

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        mainConnection = resolve("SLSMainConnectionID", as: MainConnection.self)
        setWindowAlpha = resolve("SLSSetWindowAlpha", as: SetAlpha.self)
    }

    public var isAvailable: Bool { mainConnection != nil && setWindowAlpha != nil }

    public func setAlpha(windowNumber: UInt32, alpha: Float) -> Int32? {
        guard let mainConnection, let setWindowAlpha else { return nil }
        return setWindowAlpha(mainConnection(), windowNumber, alpha)
    }
}
