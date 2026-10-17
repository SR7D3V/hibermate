import Foundation

/// The few fields Hibermate reads from a Claude Code hook's stdin JSON. All
/// other fields, including `prompt`, `last_assistant_message`, `tool_input`, and
/// `transcript_path`, are never copied out of the parsed input and are
/// discarded with it.
public struct HookEvent: Equatable, Sendable {
    public var name: String
    public var sessionID: String
    public var notificationType: String?
    /// `SessionStart` source: startup, resume, clear, compact, fork.
    public var source: String?
    public var cwd: String?
    /// `Stop`: how many background tasks are still running (the count only).
    public var backgroundTaskCount: Int?
    public var toolUseID: String?
    /// Set when the event comes from inside a subagent.
    public var agentID: String?

    public init(name: String, sessionID: String, notificationType: String? = nil, source: String? = nil,
                cwd: String? = nil, backgroundTaskCount: Int? = nil, toolUseID: String? = nil, agentID: String? = nil) {
        self.name = name
        self.sessionID = sessionID
        self.notificationType = notificationType
        self.source = source
        self.cwd = cwd
        self.backgroundTaskCount = backgroundTaskCount
        self.toolUseID = toolUseID
        self.agentID = agentID
    }

    /// Returns nil for anything that isn't a JSON object with a valid
    /// `hook_event_name` and `session_id`.
    public static func parse(_ data: Data) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let sessionID = object["session_id"] as? String,
              SessionRecord.isValidSessionID(sessionID) else { return nil }
        return HookEvent(
            name: name,
            sessionID: sessionID,
            notificationType: object["notification_type"] as? String,
            source: object["source"] as? String,
            cwd: object["cwd"] as? String,
            backgroundTaskCount: (object["background_tasks"] as? [Any])?.count,
            toolUseID: (object["tool_use_id"] as? String).flatMap { $0.utf8.count <= 128 ? $0 : nil },
            agentID: object["agent_id"] as? String
        )
    }
}

public enum RecordAction: Equatable, Sendable {
    case write(SessionRecord)
    case delete
    case ignore
}

/// Maps hook events to session states. Event names were verified against the
/// Claude Code hooks docs on 2026-10-17 (see docs/SPEC.md, Appendix A.3).
public enum HookEventMapping {
    /// Every event Hibermate registers a hook for.
    public static let registeredEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PostToolBatch", "PermissionRequest", "Notification", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "Stop", "StopFailure", "SessionEnd",
    ]

    static let waitingNotificationTypes: Set<String> = ["permission_prompt", "elicitation_dialog", "agent_needs_input"]
    static let maxToolsInFlight = 64

    public static func nextAction(existing: SessionRecord?, event e: HookEvent, now: Double) -> RecordAction {
        var r = existing ?? SessionRecord(sessionID: e.sessionID, state: .idle, event: e.name, updatedAt: now)
        let previousState = r.state

        switch e.name {
        case "SessionEnd":
            return .delete

        case "SessionStart":
            // An auto-compaction can happen mid-turn and re-fires SessionStart
            // with source "compact"; that must not drop a working session to idle.
            if e.source != "compact" {
                r.state = .idle
                r.toolsInFlight = []
                r.backgroundTaskCount = 0
            }

        case "UserPromptSubmit":
            // Also fires for turns Claude starts by itself, e.g. the next queued prompt.
            r.state = .working
            r.toolsInFlight = []

        case "PreToolUse":
            if let id = e.toolUseID, !r.toolsInFlight.contains(id), r.toolsInFlight.count < maxToolsInFlight {
                r.toolsInFlight.append(id)
            }
            r.state = activityState(from: r.state, isSubagent: e.agentID != nil)

        case "PostToolUse", "PostToolUseFailure":
            if let id = e.toolUseID { r.toolsInFlight.removeAll { $0 == id } }
            r.state = activityState(from: r.state, isSubagent: e.agentID != nil)

        case "PostToolBatch":
            r.state = activityState(from: r.state, isSubagent: e.agentID != nil)

        case "SubagentStart", "SubagentStop", "PreCompact", "PostCompact":
            // Heartbeat only. A subagent finishing never marks the session idle.
            if r.state == .waiting { r.state = .working }

        case "PermissionRequest":
            r.state = .waiting

        case "Notification":
            guard let type = e.notificationType else { return .ignore }
            if waitingNotificationTypes.contains(type) {
                r.state = .waiting
            } else if type == "idle_prompt" {
                r.state = .idle
                r.toolsInFlight = []
            } else {
                return .ignore
            }

        case "Stop":
            let background = e.backgroundTaskCount ?? 0
            r.backgroundTaskCount = background
            r.state = background > 0 ? .background : .idle
            r.toolsInFlight = []

        case "StopFailure":
            // The turn ended on an API error (rate limit, overload, auth).
            r.state = .idle
            r.toolsInFlight = []
            r.backgroundTaskCount = 0

        default:
            return .ignore
        }

        r.event = e.name
        r.updatedAt = now
        if r.state != previousState || existing == nil { r.stateSince = now }
        if let project = SessionRecord.projectName(fromCWD: e.cwd) { r.project = project }
        return .write(r)
    }

    /// A tool running means work is happening. It also means any pending
    /// permission was answered. Main-thread tool use while "idle" means a
    /// prompt event was missed. A subagent's tool use while idle doesn't
    /// re-mark the session working; background subagents are covered by `Stop`'s
    /// `background_tasks`.
    private static func activityState(from state: SessionState, isSubagent: Bool) -> SessionState {
        switch state {
        case .working, .waiting: .working
        case .background: .background
        case .idle: isSubagent ? .idle : .working
        }
    }
}
