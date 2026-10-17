import Foundation

/// Identifies an integration, e.g. "claude-code". Lowercase letters, digits,
/// and hyphens only, because it becomes a directory name.
public struct AgentID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1...32).contains(rawValue.utf8.count),
              rawValue.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D })
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let claudeCode = AgentID(rawValue: "claude-code")!
    /// Sessions started with `hibermate-hook generic …`, for tools and scripts
    /// that have no dedicated integration.
    public static let generic = AgentID(rawValue: "generic")!
}

/// What an agent's lifecycle event means for keeping the Mac awake, independent
/// of which tool sent it. Each integration maps its own event names onto these.
public enum AgentSignal: Equatable, Sendable {
    /// A session began. `resetsWork: false` for events that can fire mid-turn
    /// (e.g. Claude Code's SessionStart after an auto-compaction).
    case sessionStarted(resetsWork: Bool)
    /// A prompt was submitted (by the user, a queue, or the agent itself).
    case promptSubmitted
    case toolStarted(id: String?)
    case toolFinished(id: String?)
    /// Generic sign of work, e.g. a batch of tool calls resolved.
    case activity
    /// Refreshes the timestamp only, and clears a pending permission wait.
    /// Never marks an idle session as working (e.g. a subagent finished).
    case heartbeat
    /// Waiting for a permission answer or user input.
    case waitingForUser
    /// The turn finished. A count above zero means background tasks are still running.
    case turnFinished(backgroundTasks: Int)
    /// Done and waiting for the next prompt (also: the turn ended on an error).
    case idle
    case sessionEnded
}

/// One normalized event. Carries no prompt text, transcript, or code.
public struct AgentEvent: Equatable, Sendable {
    public var agent: AgentID
    public var sessionID: String
    public var signal: AgentSignal
    /// The tool's own event name, stored as `event` in the session file.
    public var name: String
    public var cwd: String?
    /// Set when the event comes from a subagent inside the session.
    public var isSubagent: Bool

    public init(agent: AgentID, sessionID: String, signal: AgentSignal, name: String,
                cwd: String? = nil, isSubagent: Bool = false) {
        self.agent = agent
        self.sessionID = sessionID
        self.signal = signal
        self.name = name
        self.cwd = cwd
        self.isSubagent = isSubagent
    }
}

/// Turns one tool's raw hook invocation (argv plus stdin) into an `AgentEvent`.
public protocol AgentEventParser: Sendable {
    static var agent: AgentID { get }
    /// Returns nil when the input isn't something Hibermate cares about.
    static func parse(arguments: [String], stdin: Data) -> AgentEvent?
}
