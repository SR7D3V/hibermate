import Foundation

/// Safe read-modify-write of a tool's JSON hook config (Claude Code's
/// settings.json, ~/.codex/hooks.json, ~/.cursor/hooks.json, …):
/// 1. Refuse to touch a corrupt file.
/// 2. Back up before changing anything.
/// 3. Validate the new content by re-parsing it.
/// 4. Write atomically (temp file + rename) through any symlink, keeping the
///    file's permissions.
/// 5. Abort if the file changed while being edited.
public struct HookConfigFile: Sendable {
    public var url: URL
    public var schema: HookConfigSchema
    /// Hibermate owns the whole file (e.g. ~/.copilot/hooks/hibermate.json):
    /// uninstall deletes it instead of leaving an empty shell.
    public var ownedFile: Bool
    /// Create the parent directory if it's missing (only for owned files in
    /// a tool's existing config folder).
    public var createsParentDirectory: Bool

    public init(url: URL, schema: HookConfigSchema = .claudeCode, ownedFile: Bool = false, createsParentDirectory: Bool = false) {
        self.url = url
        self.schema = schema
        self.ownedFile = ownedFile
        self.createsParentDirectory = createsParentDirectory
    }

    public struct Outcome: Equatable, Sendable {
        public var changed: Bool
        public var backup: URL?
    }

    public func isInstalled() throws -> Bool {
        let target = url.resolvingSymlinksInPath()
        guard let data = FileManager.default.contents(atPath: target.path) else { return false }
        return HookConfigMerger.containsOurs(try HookConfigMerger.parse(data), schema: schema)
    }

    @discardableResult
    public func install(now: Date = Date()) throws -> Outcome {
        let isNew = !FileManager.default.fileExists(atPath: url.resolvingSymlinksInPath().path)
        if createsParentDirectory {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return try edit(now: now, requireDirectory: true) {
            try HookConfigMerger.install(into: $0, schema: schema, isNewFile: isNew)
        }
    }

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> Outcome {
        if ownedFile {
            let target = url.resolvingSymlinksInPath()
            guard let data = FileManager.default.contents(atPath: target.path) else { return Outcome(changed: false, backup: nil) }
            // Delete only if the file still holds nothing but Hibermate's entries.
            let stripped = HookConfigMerger.removeOurs(from: try HookConfigMerger.parse(data), schema: schema)
            if case .object(let members) = stripped, members.allSatisfy({ m in schema.newFileMembers.contains { $0.key == m.key } }) {
                unlink(target.path)
                return Outcome(changed: true, backup: nil)
            }
        }
        return try edit(now: now, requireDirectory: false) { HookConfigMerger.removeOurs(from: $0, schema: schema) }
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
        let root = try HookConfigMerger.parse(original)
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

/// Claude Code's user settings file.
public typealias ClaudeSettingsFile = HookConfigFile

extension HookConfigFile {
    public static func userSettings(home: URL = HibermatePaths.currentHome()) -> HookConfigFile {
        HookConfigFile(url: home.appendingPathComponent(".claude/settings.json"), schema: .claudeCode)
    }
}
