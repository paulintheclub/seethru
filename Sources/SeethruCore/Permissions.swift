import AppKit
import ApplicationServices
import CoreGraphics

public struct PermissionStatus: Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    public var allGranted: Bool { accessibility && screenRecording }
    public func isGranted(_ p: PermissionKind) -> Bool { p == .accessibility ? accessibility : screenRecording }
}

public enum Permissions {
    public static func current() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    /// Triggers the system prompt (once) and then opens the right pane.
    public static func request(_ p: PermissionKind) {
        switch p {
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt, a non-Sendable global in Swift 6
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        openSettings(p)
    }

    public static func openSettings(_ p: PermissionKind) {
        let anchor = p == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
