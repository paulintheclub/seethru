import AppKit
import ApplicationServices
import PrivateAPI

/// Mirror backend: shows a see-through live copy of the window and parks the original off-screen.
/// Needs Screen Recording (capture) and Accessibility (moving the original).
@MainActor
public final class MirrorBackend: OpacityBackend {
    public let kind = BackendKind.mirror
    /// Click-through and always-on-top need the original out of the way (parked off-screen, needs Accessibility).
    /// Plain transparency needs only Screen Recording.
    public let capabilities: BackendCapabilities = [.alwaysOnTop, .clickThrough]
    public let requiredPermissions: [PermissionKind] = [.screenRecording]
    public var onWindowLost: (@MainActor (WindowID, BackendError?) -> Void)?

    private let resolver: any AXWindowIDResolving
    private let journal: HiddenWindowJournal
    private var sessions: [WindowID: any OverlaySession] = [:]
    private var starting: [WindowID: (value: Double, options: WindowOptions)] = [:]

    public init(resolver: any AXWindowIDResolving = DynamicAXWindowIDResolver(), journal: HiddenWindowJournal = HiddenWindowJournal()) {
        self.resolver = resolver
        self.journal = journal
    }

    public func setOpacity(_ window: WindowInfo, value: Double, options: WindowOptions) async throws {
        if value >= 0.999 && options == .none {
            restore(window.id)
            return
        }
        let wantsParked = options.clickThrough || options.alwaysOnTop
        if let s = sessions[window.id] {
            if s.isParked == wantsParked {
                s.update(alpha: value, options: options)
                return
            }
            restore(window.id) // switching between in-place and parked: start over
        }
        if starting[window.id] != nil { // a start is in flight (slider drag): remember the latest value
            starting[window.id] = (value, options)
            return
        }
        starting[window.id] = (value, options)
        let session: any OverlaySession = wantsParked
            ? MirrorSession(window: window, alpha: value, options: options, resolver: resolver, journal: journal)
            : InPlaceSession(window: window, alpha: value)
        session.onEnded = { [weak self] id, error in
            self?.sessions[id] = nil
            self?.sessionsChanged()
            self?.onWindowLost?(id, error)
        }
        do {
            try await session.start()
        } catch {
            starting[window.id] = nil
            throw error
        }
        let latest = starting.removeValue(forKey: window.id)
        sessions[window.id] = session
        sessionsChanged()
        if let latest { session.update(alpha: latest.value, options: latest.options) }
    }

    public func restore(_ id: WindowID) {
        sessions.removeValue(forKey: id)?.stop()
        sessionsChanged()
    }

    /// Backdrop captures must exclude every Seethru window, so tell them when the set changes.
    private func sessionsChanged() {
        let all = Array(sessions.values)
        Task { @MainActor in for s in all { await s.refreshFilters() } }
    }

    public func restoreAll() {
        let all = sessions.values
        sessions.removeAll()
        starting.removeAll()
        all.forEach { $0.stop() }
        journal.clear()
    }

    /// Launch-time sweep: if a previous run died while windows were parked off-screen, bring them back.
    /// Returns the number of windows recovered.
    @discardableResult
    public static func recoverHiddenWindows(journal: HiddenWindowJournal = HiddenWindowJournal(),
                                            resolver: any AXWindowIDResolving = DynamicAXWindowIDResolver()) -> Int {
        guard AXIsProcessTrusted() else { return 0 }
        var recovered = 0
        for e in journal.entries {
            guard let w = AXWindow.find(pid: e.pid, number: e.windowNumber, resolver: resolver) else { continue }
            var target = CGPoint(x: e.originX, y: e.originY)
            if !ScreenGeometry.isVisible(CGRect(origin: target, size: CGSize(width: 200, height: 100))) { target = CGPoint(x: 80, y: 80) }
            if w.setPosition(target) { recovered += 1 }
        }
        journal.clear()
        return recovered
    }
}
