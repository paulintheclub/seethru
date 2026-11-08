import AppKit

/// One 60 Hz timer and one window-list snapshot for every in-place session (instead of a timer and two list queries
/// per session, which made several transparent windows fight over the stacking order and lag).
@MainActor
final class StackCoordinator {
    private var sessions: [ObjectIdentifier: InPlaceSession] = [:]
    private var timer: Timer?
    private var mouseMonitor: Any?

    func register(_ s: InPlaceSession) {
        sessions[ObjectIdentifier(s)] = s
        guard timer == nil else { return }
        // Common run-loop modes: the timer must keep running while a menu or slider is being tracked.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A click can raise or move windows: look right away instead of at the next tick.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tick() } }
        }
    }

    func unregister(_ s: InPlaceSession) {
        sessions[ObjectIdentifier(s)] = nil
        guard sessions.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
    }

    private func tick() {
        guard !sessions.isEmpty else { return }
        let snap = WindowGeometry.snapshot()
        let ours = Set(sessions.values.flatMap(\.panelNumbers))
        for s in Array(sessions.values) { s.tick(snap, ours: ours) }
    }
}
