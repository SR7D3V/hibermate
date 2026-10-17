import Foundation

public enum SessionState: String, Codable, Sendable {
    /// A prompt is being processed.
    case working
    /// Claude is waiting for a permission answer or user input. Holds only until
    /// the permission-wait timeout, since nobody can answer with the lid closed.
    case waiting
    /// The turn ended but background tasks are still running. Holds for up to
    /// the stale window without fresh activity.
    case background
    /// Turn finished; not holding.
    case idle
}

/// Contents of `sessions/<session_id>.json`. It deliberately stores no prompt
/// text, transcript path, or code: only IDs, PIDs, timestamps, event names, and
/// the project folder name.
public struct SessionRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sessionID: String
    public var state: SessionState
    /// Last hook event name, e.g. "PostToolUse".
    public var event: String
    /// Wall-clock seconds since 1970 of the last event (a heartbeat).
    public var updatedAt: Double
    /// When `state` last changed. Used for the permission-wait timeout.
    public var stateSince: Double
    public var agentPID: Int32?
    /// Process start time of `agentPID`, to detect PID reuse.
    public var agentStartTime: Double?
    /// `basename(cwd)`, never the full path.
    public var project: String?
    public var backgroundTaskCount: Int
    /// `tool_use_id`s of tool calls that have started but not finished.
    public var toolsInFlight: [String]

    public init(sessionID: String, state: SessionState, event: String, updatedAt: Double,
                stateSince: Double? = nil, agentPID: Int32? = nil, agentStartTime: Double? = nil,
                project: String? = nil, backgroundTaskCount: Int = 0, toolsInFlight: [String] = []) {
        self.version = Self.currentVersion
        self.sessionID = sessionID
        self.state = state
        self.event = event
        self.updatedAt = updatedAt
        self.stateSince = stateSince ?? updatedAt
        self.agentPID = agentPID
        self.agentStartTime = agentStartTime
        self.project = project
        self.backgroundTaskCount = backgroundTaskCount
        self.toolsInFlight = toolsInFlight
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case sessionID = "session_id"
        case state, event
        case updatedAt = "ts"
        case stateSince = "state_since"
        case agentPID = "agent_pid"
        case agentStartTime = "agent_start"
        case project
        case backgroundTaskCount = "bg_count"
        case toolsInFlight = "tools_in_flight"
    }

    /// Session IDs become file names, so only a conservative character set is
    /// accepted. This rules out path traversal and odd file names.
    public static func isValidSessionID(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
        }
    }

    /// Reduces a working directory to a short, display-safe folder name.
    public static func projectName(fromCWD cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let base = (cwd as NSString).lastPathComponent
        let cleaned = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)).prefix(80)
        return cleaned.isEmpty ? nil : String(cleaned)
    }
}
