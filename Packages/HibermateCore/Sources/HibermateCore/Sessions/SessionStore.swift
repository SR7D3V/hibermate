import Foundation

/// Paths under `~/Library/Application Support/Hibermate/`.
public struct HibermatePaths: Sendable {
    public var supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.supportDirectory = home.appendingPathComponent("Library/Application Support/Hibermate", isDirectory: true)
    }

    public var sessionsDirectory: URL { supportDirectory.appendingPathComponent("sessions", isDirectory: true) }
    public var hooksDirectory: URL { supportDirectory.appendingPathComponent("hooks", isDirectory: true) }
    public var hookBinary: URL { hooksDirectory.appendingPathComponent("hibermate-hook") }
    public var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }

    public func sessionFile(_ sessionID: String) -> URL? {
        guard SessionRecord.isValidSessionID(sessionID) else { return nil }
        return sessionsDirectory.appendingPathComponent("\(sessionID).json")
    }
}

/// Reads and writes session files. Malformed files are never trusted; they
/// can't hold the Mac awake.
public struct SessionStore: Sendable {
    public var paths: HibermatePaths

    public init(paths: HibermatePaths) {
        self.paths = paths
    }

    public struct LoadResult: Sendable {
        public var records: [SessionRecord]
        /// Unreadable files with their modification dates, for cleanup.
        public var malformed: [(url: URL, modified: Date?)]
    }

    public func loadAll() -> LoadResult {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.sessionsDirectory.path) else {
            return LoadResult(records: [], malformed: [])
        }
        var records: [SessionRecord] = []
        var malformed: [(URL, Date?)] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = paths.sessionsDirectory.appendingPathComponent(name)
            let id = String(name.dropLast(5))
            if let data = try? Data(contentsOf: url, options: [.uncached]),
               data.count <= 64 * 1024,
               let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
               record.sessionID == id {
                records.append(record)
            } else {
                let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                malformed.append((url, modified))
            }
        }
        return LoadResult(records: records, malformed: malformed)
    }

    public func load(_ sessionID: String) -> SessionRecord? {
        guard let url = paths.sessionFile(sessionID),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
              record.sessionID == sessionID else { return nil }
        return record
    }

    public func save(_ record: SessionRecord) throws {
        guard let url = paths.sessionFile(record.sessionID) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(try encoder.encode(record), to: url)
    }

    public func remove(_ sessionID: String) {
        guard let url = paths.sessionFile(sessionID) else { return }
        unlink(url.path)
    }

    /// Deletes malformed files older than `olderThan` seconds. Fresh ones are
    /// left alone, in case a writer is mid-rename on a slow disk.
    public func removeMalformed(_ result: LoadResult, now: Date, olderThan: TimeInterval) {
        for (url, modified) in result.malformed {
            if let modified, now.timeIntervalSince(modified) < olderThan { continue }
            unlink(url.path)
        }
    }
}
