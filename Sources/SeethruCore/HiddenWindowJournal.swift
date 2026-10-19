import Foundation

/// Crash safety for the mirror backend: before an original window is moved off-screen its home position
/// is written here. On launch (and on quit) anything still listed is moved back.
public struct HiddenWindowEntry: Codable, Hashable, Sendable {
    public var pid: Int32
    public var windowNumber: UInt32
    public var originX: Double
    public var originY: Double
    public init(pid: Int32, windowNumber: UInt32, originX: Double, originY: Double) {
        self.pid = pid
        self.windowNumber = windowNumber
        self.originX = originX
        self.originY = originY
    }
}

public final class HiddenWindowJournal {
    public let url: URL
    public private(set) var entries: [HiddenWindowEntry]

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seethru", isDirectory: true)
            .appendingPathComponent("hidden-windows.json")
    }

    public init(url: URL = HiddenWindowJournal.defaultURL) {
        self.url = url
        self.entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([HiddenWindowEntry].self, from: $0) } ?? []
    }

    public func add(_ e: HiddenWindowEntry) {
        entries.removeAll { $0.pid == e.pid && $0.windowNumber == e.windowNumber }
        entries.append(e)
        persist()
    }

    public func remove(pid: Int32, windowNumber: UInt32) {
        entries.removeAll { $0.pid == pid && $0.windowNumber == windowNumber }
        persist()
    }

    public func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
