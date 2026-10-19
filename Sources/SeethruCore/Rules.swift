import Foundation

public struct AppRule: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var appName: String
    public var opacity: Double
    public var alwaysOnTop: Bool
    public var clickThrough: Bool
    public var id: String { bundleID }

    public init(bundleID: String, appName: String, opacity: Double, alwaysOnTop: Bool = false, clickThrough: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.opacity = opacity
        self.alwaysOnTop = alwaysOnTop
        self.clickThrough = clickThrough
    }

    public var options: WindowOptions { WindowOptions(alwaysOnTop: alwaysOnTop, clickThrough: clickThrough) }
}

public struct ExcludedApp: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var appName: String
    public var id: String { bundleID }
    public init(bundleID: String, appName: String) {
        self.bundleID = bundleID
        self.appName = appName
    }
}

/// On-disk document. Bump `currentVersion` and extend `RulesMigrator` when the shape changes.
public struct RulesFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var rules: [AppRule]
    public var excluded: [ExcludedApp]

    public init(version: Int = RulesFile.currentVersion, rules: [AppRule] = [], excluded: [ExcludedApp] = []) {
        self.version = version
        self.rules = rules
        self.excluded = excluded
    }

    public func rule(for bundleID: String?) -> AppRule? {
        guard let bundleID else { return nil }
        return rules.first { $0.bundleID == bundleID }
    }

    public func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excluded.contains { $0.bundleID == bundleID }
    }
}

public enum RulesError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case corrupt
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): "rules.json was written by a newer Seethru (schema v\(v))."
        case .corrupt: "rules.json could not be read."
        }
    }
}

public enum RulesMigrator {
    /// Accepts any known historic shape and returns the current one.
    /// - v0 (pre-release): a bare `{"<bundle id>": <opacity>}` object, no version, no names.
    /// - v1: `RulesFile`.
    public static func decode(_ data: Data) throws -> RulesFile {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RulesError.corrupt }
        if let version = object["version"] as? Int {
            guard version <= RulesFile.currentVersion else { throw RulesError.unsupportedVersion(version) }
            guard let file = try? JSONDecoder().decode(RulesFile.self, from: data) else { throw RulesError.corrupt }
            return file
        }
        var rules: [AppRule] = []
        for (bundleID, value) in object {
            guard let n = value as? NSNumber else { throw RulesError.corrupt }
            rules.append(AppRule(bundleID: bundleID, appName: bundleID, opacity: OpacityStepper.clamp(n.doubleValue)))
        }
        return RulesFile(rules: rules.sorted { $0.bundleID < $1.bundleID })
    }
}

public final class RulesStore {
    public let url: URL
    public private(set) var file: RulesFile

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seethru", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    public init(url: URL = RulesStore.defaultURL) {
        self.url = url
        self.file = RulesFile()
    }

    /// Loads from disk. A missing file is an empty store. An unreadable or newer file is moved aside
    /// (`rules.json.bak`) so it is never silently overwritten.
    @discardableResult
    public func load() -> RulesError? {
        guard let data = try? Data(contentsOf: url) else { file = RulesFile(); return nil }
        do {
            file = try RulesMigrator.decode(data)
            return nil
        } catch let e as RulesError {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bak"))
            file = RulesFile()
            return e
        } catch { return .corrupt }
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: url, options: .atomic)
    }

    public func upsert(_ rule: AppRule) {
        if let i = file.rules.firstIndex(where: { $0.bundleID == rule.bundleID }) { file.rules[i] = rule } else { file.rules.append(rule) }
        file.rules.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    public func removeRule(bundleID: String) { file.rules.removeAll { $0.bundleID == bundleID } }

    public func exclude(_ app: ExcludedApp) {
        removeRule(bundleID: app.bundleID)
        if !file.isExcluded(app.bundleID) { file.excluded.append(app) }
    }

    public func include(bundleID: String) { file.excluded.removeAll { $0.bundleID == bundleID } }
}
