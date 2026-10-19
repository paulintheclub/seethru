import Carbon.HIToolbox
import Foundation

public enum HotKeyAction: UInt32, CaseIterable, Sendable {
    case moreOpaque = 1
    case moreTransparent
    case reset
    case peek

    public var title: String {
        switch self {
        case .moreOpaque: "More opaque (frontmost window)"
        case .moreTransparent: "More transparent (frontmost window)"
        case .reset: "Reset frontmost window"
        case .peek: "Peek: toggle all managed windows to 20%"
        }
    }
}

public struct HotKeyBinding: Equatable, Sendable {
    public var action: HotKeyAction
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String

    /// ⌃⌥⌘ + key. Carbon hotkeys need no extra permission.
    public static let defaults: [HotKeyBinding] = {
        let mods = UInt32(controlKey | optionKey | cmdKey)
        return [
            HotKeyBinding(action: .moreOpaque, keyCode: UInt32(kVK_UpArrow), modifiers: mods, display: "⌃⌥⌘↑"),
            HotKeyBinding(action: .moreTransparent, keyCode: UInt32(kVK_DownArrow), modifiers: mods, display: "⌃⌥⌘↓"),
            HotKeyBinding(action: .reset, keyCode: UInt32(kVK_ANSI_0), modifiers: mods, display: "⌃⌥⌘0"),
            HotKeyBinding(action: .peek, keyCode: UInt32(kVK_ANSI_P), modifiers: mods, display: "⌃⌥⌘P"),
        ]
    }()
}

@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var handler: (@MainActor (HotKeyAction) -> Void)?
    private var installed: EventHandlerRef?
    private static let signature: OSType = 0x5345_4554 // 'SEET'

    /// Returns the actions whose key combo could not be registered (already taken by another app).
    @discardableResult
    public func register(_ bindings: [HotKeyBinding] = HotKeyBinding.defaults,
                         handler: @escaping @MainActor (HotKeyAction) -> Void) -> [HotKeyAction] {
        unregisterAll()
        self.handler = handler
        installHandlerIfNeeded()
        var failed: [HotKeyAction] = []
        for b in bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: b.action.rawValue)
            let status = RegisterEventHotKey(b.keyCode, b.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.append(b.action) }
        }
        return failed
    }

    public func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard installed == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let s = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard s == noErr, hk.signature == 0x5345_4554, let action = HotKeyAction(rawValue: hk.id) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.handler?(action) } }
            return noErr
        }, 1, &spec, nil, &installed)
    }
}
