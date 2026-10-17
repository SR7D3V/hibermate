import Foundation

/// Safe read-modify-write of Claude Code's settings.json:
/// 1. Refuse to touch a corrupt file.
/// 2. Back up before changing anything.
/// 3. Validate the new content by re-parsing it.
/// 4. Write atomically (temp file + rename) through any symlink, keeping the
///    file's permissions.
/// 5. Abort if the file changed while being edited.
public struct ClaudeSettingsFile: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func userSettings(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeSettingsFile {
        ClaudeSettingsFile(url: home.appendingPathComponent(".claude/settings.json"))
    }

    public struct Outcome: Equatable, Sendable {
        public var changed: Bool
        public var backup: URL?
    }

    public func isInstalled() throws -> Bool {
        let target = url.resolvingSymlinksInPath()
        guard let data = FileManager.default.contents(atPath: target.path) else { return false }
        return ClaudeSettingsMerger.containsOurs(try ClaudeSettingsMerger.parse(data))
    }

    @discardableResult
    public func install(now: Date = Date()) throws -> Outcome {
        try edit(now: now, requireDirectory: true) { try ClaudeSettingsMerger.install(into: $0) }
    }

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> Outcome {
        try edit(now: now, requireDirectory: false) { ClaudeSettingsMerger.removeOurs(from: $0) }
    }

    private func edit(now: Date, requireDirectory: Bool, _ transform: (JSONValue) throws -> JSONValue) throws -> Outcome {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else {
            if requireDirectory { throw ClaudeSettingsError.claudeDirectoryMissing }
            return Outcome(changed: false, backup: nil)
        }

        let original = fm.contents(atPath: target.path)
        if original == nil, !requireDirectory { return Outcome(changed: false, backup: nil) }
        let root = try ClaudeSettingsMerger.parse(original)
        let updated = try transform(root)
        if updated == root { return Outcome(changed: false, backup: nil) }

        let writer = original.map(OrderedJSONWriter.matchingStyle(of:)) ?? OrderedJSONWriter()
        let newData = writer.serialize(updated)
        // Validate: the output must re-parse to the same value with both parsers.
        guard (try? OrderedJSONParser.parse(newData)) == updated,
              (try? JSONSerialization.jsonObject(with: newData)) != nil else {
            throw ClaudeSettingsError.io("generated settings failed validation")
        }

        var backup: URL?
        var permissions: mode_t = 0o600
        if let original {
            let stamp = Self.timestamp(now)
            let backupURL = target.deletingLastPathComponent().appendingPathComponent("\(target.lastPathComponent).hibermate-backup-\(stamp)")
            do {
                try AtomicFile.write(original, to: backupURL)
            } catch {
                throw ClaudeSettingsError.io("could not write backup: \(error)")
            }
            backup = backupURL
            if let mode = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
                permissions = mode_t(mode.uint16Value)
            }
        }

        // Re-read right before replacing. If Claude Code or the user wrote in
        // the meantime, abort instead of overwriting their change.
        guard fm.contents(atPath: target.path) == original else { throw ClaudeSettingsError.concurrentModification }
        do {
            try AtomicFile.write(newData, to: target, permissions: permissions)
        } catch {
            throw ClaudeSettingsError.io("could not write settings: \(error)")
        }
        return Outcome(changed: true, backup: backup)
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
