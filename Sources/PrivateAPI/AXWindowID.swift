import ApplicationServices
import CoreGraphics
import Foundation

/// Maps an Accessibility window element to its CGWindowID.
/// `_AXUIElementGetWindow` is private but long-stable; there is no public equivalent.
public protocol AXWindowIDResolving: Sendable {
    var isAvailable: Bool { get }
    func windowNumber(of element: AXUIElement) -> CGWindowID?
}

public struct DynamicAXWindowIDResolver: AXWindowIDResolving {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let fn: GetWindow?

    public init() {
        // RTLD_DEFAULT
        let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        fn = p.map { unsafeBitCast($0, to: GetWindow.self) }
    }

    public var isAvailable: Bool { fn != nil }

    public func windowNumber(of element: AXUIElement) -> CGWindowID? {
        guard let fn else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success ? id : nil
    }
}
