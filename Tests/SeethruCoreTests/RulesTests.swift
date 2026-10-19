import Foundation
import Testing
@testable import SeethruCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("seethru-tests-\(UUID().uuidString)/rules.json")
}

@Suite struct RulesStoreTests {
    @Test func roundTrips() throws {
        let url = tempURL()
        let a = RulesStore(url: url)
        a.upsert(AppRule(bundleID: "com.apple.Safari", appName: "Safari", opacity: 0.6, alwaysOnTop: true))
        a.exclude(ExcludedApp(bundleID: "com.apple.finder", appName: "Finder"))
        try a.save()

        let b = RulesStore(url: url)
        #expect(b.load() == nil)
        #expect(b.file == a.file)
        #expect(b.file.version == RulesFile.currentVersion)
        #expect(b.file.rule(for: "com.apple.Safari")?.alwaysOnTop == true)
        #expect(b.file.isExcluded("com.apple.finder"))
    }

    @Test func missingFileIsEmpty() {
        let s = RulesStore(url: tempURL())
        #expect(s.load() == nil)
        #expect(s.file.rules.isEmpty)
    }

    @Test func upsertReplacesAndKeepsSortedByName() {
        let s = RulesStore(url: tempURL())
        s.upsert(AppRule(bundleID: "b", appName: "Beta", opacity: 0.5))
        s.upsert(AppRule(bundleID: "a", appName: "alpha", opacity: 0.5))
        s.upsert(AppRule(bundleID: "b", appName: "Beta", opacity: 0.3))
        #expect(s.file.rules.map(\.bundleID) == ["a", "b"])
        #expect(s.file.rule(for: "b")?.opacity == 0.3)
    }

    @Test func excludingDropsTheRule() {
        let s = RulesStore(url: tempURL())
        s.upsert(AppRule(bundleID: "x", appName: "X", opacity: 0.5))
        s.exclude(ExcludedApp(bundleID: "x", appName: "X"))
        #expect(s.file.rule(for: "x") == nil)
        #expect(s.file.isExcluded("x"))
        s.include(bundleID: "x")
        #expect(!s.file.isExcluded("x"))
    }

    @Test func migratesVersionlessV0File() throws {
        let data = #"{"com.apple.Safari": 0.5, "com.apple.Terminal": 5}"#.data(using: .utf8)!
        let file = try RulesMigrator.decode(data)
        #expect(file.version == RulesFile.currentVersion)
        #expect(file.rule(for: "com.apple.Safari")?.opacity == 0.5)
        #expect(file.rule(for: "com.apple.Terminal")?.opacity == 1.0) // clamped
    }

    @Test func rejectsNewerSchemaAndKeepsABackup() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version": 99, "rules": [], "excluded": []}"#.write(to: url, atomically: true, encoding: .utf8)
        let s = RulesStore(url: url)
        #expect(s.load() == .unsupportedVersion(99))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        #expect(s.file.rules.isEmpty)
    }

    @Test func corruptFileIsMovedAside() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let s = RulesStore(url: url)
        #expect(s.load() == .corrupt)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
}

@Suite struct RuleApplierTests {
    private func win(_ n: UInt32, bundle: String?) -> WindowInfo {
        WindowInfo(id: WindowID(pid: 1, number: n), ownerName: "App", bundleID: bundle)
    }

    @Test func appliesRuleToNewWindowsOnly() {
        let rules = RulesFile(rules: [AppRule(bundleID: "a", appName: "A", opacity: 0.4)])
        let plan = RuleApplier.plan(windows: [win(1, bundle: "a"), win(2, bundle: "a"), win(3, bundle: "b")],
                                    rules: rules, handled: [WindowID(pid: 1, number: 2)])
        #expect(plan.map(\.window.id.number) == [1])
        #expect(plan[0].opacity == 0.4)
    }

    @Test func skipsExcludedApps() {
        let rules = RulesFile(rules: [AppRule(bundleID: "a", appName: "A", opacity: 0.4)], excluded: [ExcludedApp(bundleID: "a", appName: "A")])
        #expect(RuleApplier.plan(windows: [win(1, bundle: "a")], rules: rules, handled: []).isEmpty)
    }

    @Test func fullyOpaqueRuleWithoutOptionsIsANoOp() {
        let rules = RulesFile(rules: [AppRule(bundleID: "a", appName: "A", opacity: 1)])
        #expect(RuleApplier.plan(windows: [win(1, bundle: "a")], rules: rules, handled: []).isEmpty)
    }

    @Test func carriesOptions() {
        let rules = RulesFile(rules: [AppRule(bundleID: "a", appName: "A", opacity: 1, alwaysOnTop: true, clickThrough: true)])
        let plan = RuleApplier.plan(windows: [win(1, bundle: "a")], rules: rules, handled: [])
        #expect(plan.first?.options == WindowOptions(alwaysOnTop: true, clickThrough: true))
    }

    @Test func windowsWithoutBundleIDAreIgnored() {
        let rules = RulesFile(rules: [AppRule(bundleID: "a", appName: "A", opacity: 0.4)])
        #expect(RuleApplier.plan(windows: [win(1, bundle: nil)], rules: rules, handled: []).isEmpty)
    }
}

@Suite struct HiddenWindowJournalTests {
    @Test func persistsAndRemoves() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seethru-j-\(UUID().uuidString)/h.json")
        let j = HiddenWindowJournal(url: url)
        j.add(HiddenWindowEntry(pid: 1, windowNumber: 2, originX: 10, originY: 20))
        j.add(HiddenWindowEntry(pid: 1, windowNumber: 2, originX: 11, originY: 21)) // replaces
        #expect(HiddenWindowJournal(url: url).entries == [HiddenWindowEntry(pid: 1, windowNumber: 2, originX: 11, originY: 21)])
        j.remove(pid: 1, windowNumber: 2)
        #expect(HiddenWindowJournal(url: url).entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
