import Foundation
import Testing
@testable import SeethruCore

@MainActor
final class FakeBackend: OpacityBackend {
    let kind = BackendKind.mirror
    let capabilities: BackendCapabilities = [.alwaysOnTop, .clickThrough]
    let requiredPermissions: [PermissionKind] = []
    var onWindowLost: (@MainActor (WindowID, BackendError?) -> Void)?
    var applied: [WindowID: Double] = [:]
    var failWith: BackendError?
    var restoreAllCount = 0

    func setOpacity(_ window: WindowInfo, value: Double, options: WindowOptions) async throws {
        if let failWith { throw failWith }
        applied[window.id] = value
    }
    func restore(_ id: WindowID) { applied[id] = nil }
    func restoreAll() { applied.removeAll(); restoreAllCount += 1 }
}

final class FakeWindows: WindowListing, @unchecked Sendable {
    var list: [WindowInfo] = []
    func snapshot() -> [WindowInfo] { list }
    func windowExists(_ id: WindowID) -> Bool { list.contains { $0.id == id } }
}

@MainActor
private func makeModel(windows: FakeWindows, backend: FakeBackend, rules: RulesFile = RulesFile()) -> AppModel {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("seethru-m-\(UUID().uuidString)/rules.json")
    let store = RulesStore(url: url)
    rules.rules.forEach(store.upsert)
    rules.excluded.forEach(store.exclude)
    let suite = UserDefaults(suiteName: "seethru-tests-\(UUID().uuidString)")!
    let m = AppModel(windows: windows, store: store, defaults: suite, makeBackend: { _ in backend })
    return m
}

private func win(_ n: UInt32, pid: Int32 = 5, bundle: String? = "com.test.app") -> WindowInfo {
    WindowInfo(id: WindowID(pid: pid, number: n), ownerName: "Test", bundleID: bundle, title: "w\(n)")
}

private func settle() async { try? await Task.sleep(nanoseconds: 60_000_000) }

@MainActor
@Suite struct AppModelTests {
    @Test func settingOpacityReachesTheBackendAndResetRestores() async {
        let ws = FakeWindows(); ws.list = [win(1)]
        let backend = FakeBackend()
        let m = makeModel(windows: ws, backend: backend)
        m.refresh()
        m.setOpacity(ws.list[0], 0.5)
        await settle()
        #expect(backend.applied[ws.list[0].id] == 0.5)
        #expect(m.activeCount == 1)
        m.reset(ws.list[0].id)
        #expect(backend.applied.isEmpty)
        #expect(m.activeCount == 0)
    }

    @Test func fullOpacityMeansRestoreNotManage() async {
        let ws = FakeWindows(); ws.list = [win(1)]
        let backend = FakeBackend()
        let m = makeModel(windows: ws, backend: backend)
        m.setOpacity(ws.list[0], 0.5); await settle()
        m.setOpacity(ws.list[0], 1.0); await settle()
        #expect(m.activeCount == 0)
        #expect(backend.applied.isEmpty)
    }

    @Test func peekCapsManagedWindowsAndRestoresTheirValues() async {
        let ws = FakeWindows(); ws.list = [win(1), win(2)]
        let backend = FakeBackend()
        let m = makeModel(windows: ws, backend: backend)
        m.setOpacity(ws.list[0], 0.7); m.setOpacity(ws.list[1], 0.1); await settle()
        m.togglePeek(); await settle()
        #expect(backend.applied[ws.list[0].id] == 0.2)
        #expect(backend.applied[ws.list[1].id] == 0.1)
        m.togglePeek(); await settle()
        #expect(backend.applied[ws.list[0].id] == 0.7)
    }

    @Test func rulesApplyToNewWindowsOnRefresh() async {
        let ws = FakeWindows()
        let backend = FakeBackend()
        let rules = RulesFile(rules: [AppRule(bundleID: "com.test.app", appName: "Test", opacity: 0.4)])
        let m = makeModel(windows: ws, backend: backend, rules: rules)
        ws.list = [win(1)]
        m.refresh(); await settle()
        #expect(backend.applied[ws.list[0].id] == 0.4)
        m.reset(ws.list[0].id) // user override must stick across refreshes
        m.refresh(); await settle()
        #expect(backend.applied.isEmpty)
    }

    @Test func backendFailureSurfacesAnErrorAndDropsTheWindow() async {
        let ws = FakeWindows(); ws.list = [win(1)]
        let backend = FakeBackend(); backend.failWith = .refusedByWindowServer
        let m = makeModel(windows: ws, backend: backend)
        m.setOpacity(ws.list[0], 0.5); await settle()
        #expect(m.lastError != nil)
        #expect(m.activeCount == 0)
    }

    @Test func managedWindowParkedOffScreenStaysListed() async {
        let ws = FakeWindows(); ws.list = [win(1)]
        let backend = FakeBackend()
        let m = makeModel(windows: ws, backend: backend)
        m.refresh()
        m.setOpacity(ws.list[0], 0.5); await settle()
        let parked = ws.list[0]
        ws.list = [] // gone from the on-screen list...
        m.refresh()
        #expect(m.activeCount == 0) // ...and really gone (windowExists == false) -> forgotten
        ws.list = [parked]
        m.setOpacity(parked, 0.5); await settle()
        #expect(m.activeCount == 1)
    }

    @Test func resetAllClearsEverything() async {
        let ws = FakeWindows(); ws.list = [win(1), win(2)]
        let backend = FakeBackend()
        let m = makeModel(windows: ws, backend: backend)
        ws.list.forEach { m.setOpacity($0, 0.5) }; await settle()
        m.resetAll()
        #expect(m.activeCount == 0)
        #expect(backend.applied.isEmpty)
    }

    @Test func rememberAndExcludeUpdateRules() {
        let ws = FakeWindows(); ws.list = [win(1)]
        let backend = FakeBackend()
        let m = makeModel(windows: ws, backend: backend)
        m.refresh()
        let g = m.groups[0]
        m.setOpacity(app: g, 0.5)
        m.remember(app: g)
        #expect(m.rule(for: g)?.opacity == 0.5)
        m.setOpacity(app: g, 0.3)
        #expect(m.rule(for: g)?.opacity == 0.3)
        m.exclude(app: g)
        #expect(m.rule(for: g) == nil)
        #expect(m.rules.isExcluded("com.test.app"))
    }
}
