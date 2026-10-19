import AppKit
import ApplicationServices
import CoreGraphics
import PrivateAPI

/// Thin wrapper over an Accessibility window element (main-thread use only).
struct AXWindow {
    let element: AXUIElement

    static func find(pid: pid_t, number: UInt32, resolver: any AXWindowIDResolving) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        for w in windows where resolver.windowNumber(of: w) == number { return AXWindow(element: w) }
        return nil
    }

    var position: CGPoint? {
        var p = CGPoint.zero
        return axValue(kAXPositionAttribute).map { AXValueGetValue($0, .cgPoint, &p) ? p : nil } ?? nil
    }

    var size: CGSize? {
        var s = CGSize.zero
        return axValue(kAXSizeAttribute).map { AXValueGetValue($0, .cgSize, &s) ? s : nil } ?? nil
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    func raise() { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }

    private func axValue(_ attr: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(ref as AnyObject, to: AXValue.self)
    }
}

enum ScreenGeometry {
    /// Screen frames in CG global coordinates (origin top-left of the primary display).
    static func cgScreenFrames() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { s in
            CGRect(x: s.frame.minX, y: primary.frame.height - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
    }

    static func isVisible(_ rect: CGRect) -> Bool {
        cgScreenFrames().contains { $0.intersects(rect) }
    }

    /// AppKit frame (bottom-left origin) for a rect given in CG coordinates.
    static func appKitFrame(fromCG r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
