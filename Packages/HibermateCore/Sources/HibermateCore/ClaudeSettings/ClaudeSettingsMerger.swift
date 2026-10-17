import Foundation

public enum ClaudeSettingsError: Error, Equatable {
    /// The existing file isn't valid JSON. Hibermate refuses to edit it.
    case corrupt(String)
    /// The top level, or `hooks`, isn't a JSON object.
    case unexpectedShape(String)
    /// The tool's settings directory doesn't exist (tool not installed or never run).
    case claudeDirectoryMissing
    /// The file changed while being edited; nothing was written.
    case concurrentModification
    case io(String)
}

/// Claude Code's settings.json: `HookConfigMerger` with the Claude schema.
public enum ClaudeSettingsMerger {
    public static let marker = HookConfigSchema.marker
    public static var hookCommand: String { HookConfigSchema.claudeCode.command(for: "") }

    public static func isOurs(_ handler: JSONValue) -> Bool {
        HookConfigSchema.claudeCode.isOurs(handler)
    }

    public static func parse(_ data: Data?) throws -> JSONValue {
        try HookConfigMerger.parse(data)
    }

    public static func install(into root: JSONValue, events: [String] = ClaudeCodeParser.registeredEvents) throws -> JSONValue {
        var schema = HookConfigSchema.claudeCode
        schema.events = events
        return try HookConfigMerger.install(into: root, schema: schema)
    }

    public static func removeOurs(from root: JSONValue) -> JSONValue {
        HookConfigMerger.removeOurs(from: root, schema: .claudeCode)
    }

    public static func containsOurs(_ root: JSONValue) -> Bool {
        HookConfigMerger.containsOurs(root, schema: .claudeCode)
    }
}
