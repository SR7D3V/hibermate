import Foundation

/// Paths under `~/Library/Application Support/Hibermate/`.
public struct HibermatePaths: Sendable {
    public var supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// Defaults to `$HOME`, to match the `$HOME` path in hook commands, and
    /// falls back to the account's home directory.
    public init(home: URL = HibermatePaths.currentHome()) {
        self.supportDirectory = home.appendingPathComponent("Library/Application Support/Hibermate", isDirectory: true)
    }

    public static func currentHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public var sessionsDirectory: URL { supportDirectory.appendingPathComponent("sessions", isDirectory: true) }
    public var hooksDirectory: URL { supportDirectory.appendingPathComponent("hooks", isDirectory: true) }
    public var hookBinary: URL { hooksDirectory.appendingPathComponent("hibermate-hook") }
    public var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }

    public func agentDirectory(_ agent: AgentID) -> URL {
        sessionsDirectory.appendingPathComponent(agent.rawValue, isDirectory: true)
    }

    public func sessionFile(_ agent: AgentID, _ sessionID: String) -> URL? {
        guard SessionRecord.isValidSessionID(sessionID) else { return nil }
        return agentDirectory(agent).appendingPathComponent("\(sessionID).json")
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
        var records: [SessionRecord] = []
        var malformed: [(URL, Date?)] = []
        guard let agentDirs = try? fm.contentsOfDirectory(atPath: paths.sessionsDirectory.path) else {
            return LoadResult(records: [], malformed: [])
        }
        for dirName in agentDirs {
            guard let agent = AgentID(rawValue: dirName),
                  let names = try? fm.contentsOfDirectory(atPath: paths.agentDirectory(agent).path) else { continue }
            for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let url = paths.agentDirectory(agent).appendingPathComponent(name)
                let id = String(name.dropLast(5))
                if let data = try? Data(contentsOf: url, options: [.uncached]),
                   data.count <= 64 * 1024,
                   let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
                   record.sessionID == id, record.agent == agent {
                    records.append(record)
                } else {
                    let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                    malformed.append((url, modified))
                }
            }
        }
        return LoadResult(records: records, malformed: malformed)
    }

    public func load(_ agent: AgentID, _ sessionID: String) -> SessionRecord? {
        guard let url = paths.sessionFile(agent, sessionID),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
              record.sessionID == sessionID, record.agent == agent else { return nil }
        return record
    }

    public func save(_ record: SessionRecord) throws {
        guard let url = paths.sessionFile(record.agent, record.sessionID) else { return }
        try? FileManager.default.createDirectory(at: paths.agentDirectory(record.agent), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(try encoder.encode(record), to: url)
    }

    public func remove(_ agent: AgentID, _ sessionID: String) {
        guard let url = paths.sessionFile(agent, sessionID) else { return }
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
