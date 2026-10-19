import AppKit
import Observation

/// The engine behind the menu bar UI: owns the window list, the managed opacities, rules, and the backend.
@MainActor
@Observable
public final class AppModel {
    // MARK: observable state
    public private(set) var groups: [AppGroup] = []
    /// Windows currently made see-through, with the value the user chose (before peek).
    public private(set) var opacities: [WindowID: Double] = [:]
    public private(set) var options: [WindowID: WindowOptions] = [:]
    public private(set) var peek = false
    public private(set) var permissions = PermissionStatus(accessibility: false, screenRecording: false)
    public private(set) var lastError: String?
    public private(set) var rules = RulesFile()
    public private(set) var failedHotKeys: [HotKeyAction] = []
    public private(set) var recoveredWindows = 0

    public var backendKind: BackendKind {
        didSet {
            guard oldValue != backendKind else { return }
            defaults.set(backendKind.rawValue, forKey: Self.backendKey)
            switchBackend()
        }
    }

    public var activeCount: Int { opacities.count }
    public var capabilities: BackendCapabilities { backend.capabilities }
    public var missingPermissions: [PermissionKind] { backend.requiredPermissions.filter { !permissions.isGranted($0) } }

    // MARK: collaborators
    @ObservationIgnored private let windows: any WindowListing
    @ObservationIgnored private let store: RulesStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeBackend: @MainActor (BackendKind) -> any OpacityBackend
    @ObservationIgnored private var backend: any OpacityBackend
    @ObservationIgnored private var snapshot: [WindowInfo] = []
    @ObservationIgnored private var knownManaged: [WindowID: WindowInfo] = [:]
    @ObservationIgnored private var handled: Set<WindowID> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let backendKey = "backend"

    public init(windows: any WindowListing = CGWindowService(),
                store: RulesStore = RulesStore(),
                defaults: UserDefaults = .standard,
                makeBackend: @escaping @MainActor (BackendKind) -> any OpacityBackend = AppModel.defaultBackend) {
        self.windows = windows
        self.store = store
        self.defaults = defaults
        self.makeBackend = makeBackend
        let kind = defaults.string(forKey: Self.backendKey).flatMap(BackendKind.init(rawValue:)) ?? .mirror
        self.backendKind = kind
        self.backend = makeBackend(kind)
        self.rules = store.file
        wire(backend)
    }

    public static func defaultBackend(_ kind: BackendKind) -> any OpacityBackend {
        switch kind {
        case .mirror: MirrorBackend()
        case .skyLight: SkyLightBackend()
        }
    }

    // MARK: lifecycle

    public func start() {
        if let e = store.load() { lastError = e.localizedDescription }
        rules = store.file
        recoveredWindows = MirrorBackend.recoverHiddenWindows()
        let failed = HotKeyCenter.shared.register { [weak self] in self?.handle($0) }
        failedHotKeys = failed
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.3
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyAfterWake() }
        })
    }

    /// Put every window back. Called on quit, on SIGTERM/SIGINT and from "Reset all".
    public func shutdown() {
        timer?.invalidate()
        backend.restoreAll()
        HotKeyCenter.shared.unregisterAll()
    }

    // MARK: refresh

    public func refresh() {
        permissions = Permissions.current()
        snapshot = windows.snapshot()
        for w in snapshot where opacities[w.id] != nil { knownManaged[w.id] = w }

        // Managed windows that left the on-screen list may just be parked off-screen by the backend.
        let present = Set(snapshot.map(\.id))
        for id in opacities.keys where !present.contains(id) && !windows.windowExists(id) { forget(id) }
        handled.formIntersection(present.union(opacities.keys))

        let hiddenManaged = opacities.keys.filter { !present.contains($0) }.compactMap { knownManaged[$0] }
        let next = WindowFilter.group(snapshot + hiddenManaged)
        if next != groups { groups = next }

        for action in RuleApplier.plan(windows: snapshot, rules: rules, handled: handled) {
            handled.insert(action.window.id)
            set(action.window, opacity: action.opacity, options: action.options)
        }
    }

    // MARK: user actions

    public func opacity(of id: WindowID) -> Double { opacities[id] ?? 1 }
    public func windowOptions(of id: WindowID) -> WindowOptions { options[id] ?? .none }
    public func rule(for group: AppGroup) -> AppRule? { rules.rule(for: group.bundleID) }
    public func isManaged(_ id: WindowID) -> Bool { opacities[id] != nil }

    public func setOpacity(_ window: WindowInfo, _ value: Double) {
        handled.insert(window.id)
        set(window, opacity: value, options: windowOptions(of: window.id))
    }

    public func setOpacity(app group: AppGroup, _ value: Double) {
        for w in group.windows { setOpacity(w, value) }
        if var rule = rule(for: group) {
            rule.opacity = OpacityStepper.clamp(value)
            updateRule(rule)
        }
    }

    public func setOptions(app group: AppGroup, _ new: WindowOptions) {
        for w in group.windows {
            handled.insert(w.id)
            set(w, opacity: opacity(of: w.id), options: new)
        }
        if var rule = rule(for: group) {
            rule.alwaysOnTop = new.alwaysOnTop
            rule.clickThrough = new.clickThrough
            updateRule(rule)
        }
    }

    public func reset(_ id: WindowID) {
        handled.insert(id)
        forget(id)
        backend.restore(id)
    }

    public func reset(app group: AppGroup) { group.windows.forEach { reset($0.id) } }

    public func resetAll() {
        backend.restoreAll()
        for id in opacities.keys { handled.insert(id) }
        opacities.removeAll()
        options.removeAll()
        knownManaged.removeAll()
        peek = false
        lastError = nil
    }

    public func togglePeek() {
        peek.toggle()
        for id in opacities.keys { if let w = info(for: id) { apply(w) } }
    }

    public func clearError() { lastError = nil }

    // MARK: rules

    public func remember(app group: AppGroup) {
        guard let bundleID = group.bundleID else { return }
        let value = group.windows.map { opacity(of: $0.id) }.min() ?? 1
        let o = group.windows.first.map { windowOptions(of: $0.id) } ?? .none
        updateRule(AppRule(bundleID: bundleID, appName: group.name, opacity: value, alwaysOnTop: o.alwaysOnTop, clickThrough: o.clickThrough))
    }

    public func forgetRule(bundleID: String) {
        store.removeRule(bundleID: bundleID)
        commitRules()
    }

    public func exclude(app group: AppGroup) {
        guard let bundleID = group.bundleID else { return }
        reset(app: group)
        store.exclude(ExcludedApp(bundleID: bundleID, appName: group.name))
        commitRules()
    }

    public func include(bundleID: String) {
        store.include(bundleID: bundleID)
        commitRules()
    }

    private func updateRule(_ rule: AppRule) {
        store.upsert(rule)
        commitRules()
    }

    private func commitRules() {
        do { try store.save() } catch { lastError = "Could not save rules: \(error.localizedDescription)" }
        rules = store.file
    }

    // MARK: hotkeys

    public func handle(_ action: HotKeyAction) {
        switch action {
        case .peek:
            togglePeek()
        case .moreOpaque, .moreTransparent, .reset:
            snapshot = windows.snapshot()
            guard let target = frontmostWindow() else { return }
            switch action {
            case .reset: reset(target.id)
            case .moreOpaque:
                guard isManaged(target.id) else { return }
                finishStep(target, OpacityStepper.step(opacity(of: target.id), .moreOpaque))
            default:
                finishStep(target, OpacityStepper.step(opacity(of: target.id), .moreTransparent))
            }
        }
    }

    private func finishStep(_ w: WindowInfo, _ value: Double) {
        if value >= 0.999 { reset(w.id) } else { setOpacity(w, value) }
    }

    /// Top-most normal window of the frontmost app. Falls back to a managed window of that app, because a
    /// mirrored original is parked off-screen and may not be in the on-screen list.
    func frontmostWindow() -> WindowInfo? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return WindowFilter.frontmostWindow(of: pid, in: snapshot)
            ?? opacities.keys.first { $0.pid == pid }.flatMap { knownManaged[$0] }
    }

    // MARK: internals

    private func info(for id: WindowID) -> WindowInfo? {
        snapshot.first { $0.id == id } ?? knownManaged[id]
    }

    private func set(_ w: WindowInfo, opacity value: Double, options new: WindowOptions) {
        let v = OpacityStepper.clamp(value)
        if v >= 0.999 && new == .none {
            forget(w.id)
            backend.restore(w.id)
            return
        }
        opacities[w.id] = v
        options[w.id] = new
        knownManaged[w.id] = w
        apply(w)
    }

    private func apply(_ w: WindowInfo) {
        guard let base = opacities[w.id] else { return }
        let value = OpacityStepper.effective(base, peek: peek)
        let opts = options[w.id] ?? .none
        Task { @MainActor in
            do {
                try await backend.setOpacity(w, value: value, options: opts)
                if opacities[w.id] == nil { backend.restore(w.id) } // reset while the backend was still starting
                else { lastError = nil }
            } catch {
                forget(w.id)
                backend.restore(w.id)
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func forget(_ id: WindowID) {
        opacities[id] = nil
        options[id] = nil
        knownManaged[id] = nil
    }

    private func wire(_ b: any OpacityBackend) {
        b.onWindowLost = { [weak self] id, error in
            guard let self else { return }
            self.forget(id)
            if let error { self.lastError = error.errorDescription }
        }
    }

    private func switchBackend() {
        let previous = opacities
        let prevOptions = options
        let infos = previous.keys.compactMap { info(for: $0) }
        backend.restoreAll()
        backend = makeBackend(backendKind)
        wire(backend)
        lastError = nil
        opacities = previous
        options = prevOptions
        infos.forEach(apply)
    }

    private func reapplyAfterWake() {
        let infos = opacities.keys.compactMap { info(for: $0) }
        backend.restoreAll()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            infos.forEach { self.apply($0) }
        }
    }
}
