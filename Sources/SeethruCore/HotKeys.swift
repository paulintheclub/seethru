import Carbon.HIToolbox
import Foundation

public enum HotKeyAction: UInt32, CaseIterable, Sendable {
    case moreOpaque = 1
    case moreTransparent
    case reset

    public var title: String {
        switch self {
        case .moreOpaque: "More opaque (frontmost window)"
        case .moreTransparent: "More transparent (frontmost window)"
        case .reset: "Reset frontmost window"
        }
    }
}

public struct HotKeyBinding: Equatable, Sendable {
    public var action: HotKeyAction
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String
    /// Extra spelling of the same shortcut (the numpad has its own keys). Not shown in Settings.
    public var isAlias = false

    /// ⌘⇧ + key. Carbon hotkeys need no extra permission. "+" is Shift and the "=" key, so no extra Shift is needed.
    public static let defaults: [HotKeyBinding] = {
        let mods = UInt32(cmdKey | shiftKey)
        return [
            HotKeyBinding(action: .moreOpaque, keyCode: UInt32(kVK_ANSI_Equal), modifiers: mods, display: "⌘⇧+"),
            HotKeyBinding(action: .moreTransparent, keyCode: UInt32(kVK_ANSI_Minus), modifiers: mods, display: "⌘⇧-"),
            HotKeyBinding(action: .reset, keyCode: UInt32(kVK_ANSI_0), modifiers: mods, display: "⌘⇧0"),
        ]
    }()

    /// The same shortcuts on the numpad keys. Not shown in Settings.
    public static let aliases: [HotKeyBinding] = {
        let mods = UInt32(cmdKey | shiftKey)
        return [
            HotKeyBinding(action: .moreOpaque, keyCode: UInt32(kVK_ANSI_KeypadPlus), modifiers: mods, display: "⌘⇧ numpad +", isAlias: true),
            HotKeyBinding(action: .moreTransparent, keyCode: UInt32(kVK_ANSI_KeypadMinus), modifiers: mods, display: "⌘⇧ numpad -", isAlias: true),
            HotKeyBinding(action: .reset, keyCode: UInt32(kVK_ANSI_Keypad0), modifiers: mods, display: "⌘⇧ numpad 0", isAlias: true),
        ]
    }()
}

@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var handler: (@MainActor (HotKeyAction) -> Void)?
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var installed: EventHandlerRef?
    private static let signature: OSType = 0x5345_4554 // 'SEET'

    /// Returns the actions whose key combo could not be registered (already taken by another app).
    @discardableResult
    public func register(_ bindings: [HotKeyBinding] = HotKeyBinding.defaults + HotKeyBinding.aliases,
                         handler: @escaping @MainActor (HotKeyAction) -> Void) -> [HotKeyAction] {
        unregisterAll()
        self.handler = handler
        installHandlerIfNeeded()
        var failed: [HotKeyAction] = []
        actionsByID = [:]
        for (index, b) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let number = UInt32(index + 1)
            actionsByID[number] = b.action
            let id = EventHotKeyID(signature: Self.signature, id: number)
            let status = RegisterEventHotKey(b.keyCode, b.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else if !b.isAlias { failed.append(b.action) }
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
            guard s == noErr, hk.signature == 0x5345_4554 else { return OSStatus(eventNotHandledErr) }
            let number = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = HotKeyCenter.shared
                    if let action = center.actionsByID[number] { center.handler?(action) }
                }
            }
            return noErr
        }, 1, &spec, nil, &installed)
    }
}
