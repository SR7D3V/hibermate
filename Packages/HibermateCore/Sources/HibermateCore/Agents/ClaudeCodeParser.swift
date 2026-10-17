import Foundation

/// Claude Code hooks: JSON on stdin. Event names were verified against
/// https://code.claude.com/docs/en/hooks on 2026-10-17 (docs/SPEC.md, A.3).
public enum ClaudeCodeParser: AgentEventParser {
    public static let agent = AgentID.claudeCode

    /// Every event Hibermate registers a hook for.
    public static let registeredEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PostToolBatch", "PermissionRequest", "Notification", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "Stop", "StopFailure", "SessionEnd",
    ]

    static let waitingNotificationTypes: Set<String> = ["permission_prompt", "elicitation_dialog", "agent_needs_input"]

    /// Reads only `hook_event_name`, `session_id`, `notification_type`, `source`,
    /// `cwd`, `tool_use_id`, `agent_id`, and the count of `background_tasks`.
    /// `prompt`, `last_assistant_message`, `tool_input`, and `transcript_path`
    /// are never copied out and are discarded with the parsed input.
    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        guard let o = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let name = o["hook_event_name"] as? String,
              let sessionID = o["session_id"] as? String,
              SessionRecord.isValidSessionID(sessionID) else { return nil }
        let toolID = (o["tool_use_id"] as? String).flatMap { $0.utf8.count <= 128 ? $0 : nil }

        let signal: AgentSignal
        switch name {
        case "SessionStart":
            signal = .sessionStarted(resetsWork: (o["source"] as? String) != "compact")
        case "UserPromptSubmit":
            signal = .promptSubmitted
        case "PreToolUse":
            signal = .toolStarted(id: toolID)
        case "PostToolUse", "PostToolUseFailure":
            signal = .toolFinished(id: toolID)
        case "PostToolBatch":
            signal = .activity
        case "SubagentStart", "SubagentStop", "PreCompact", "PostCompact":
            signal = .heartbeat
        case "PermissionRequest":
            signal = .waitingForUser
        case "Notification":
            guard let type = o["notification_type"] as? String else { return nil }
            if waitingNotificationTypes.contains(type) {
                signal = .waitingForUser
            } else if type == "idle_prompt" {
                signal = .idle
            } else {
                return nil
            }
        case "Stop":
            signal = .turnFinished(backgroundTasks: (o["background_tasks"] as? [Any])?.count ?? 0)
        case "StopFailure":
            signal = .idle
        case "SessionEnd":
            signal = .sessionEnded
        default:
            return nil
        }
        return AgentEvent(agent: agent, sessionID: sessionID, signal: signal, name: name,
                          cwd: o["cwd"] as? String, isSubagent: o["agent_id"] is String)
    }
}

/// `hibermate-hook generic <start|heartbeat|wait|stop|end> <session-id>`, for
/// wiring up any tool or script that can run a command at start and finish.
public enum GenericParser: AgentEventParser {
    public static let agent = AgentID.generic

    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        guard arguments.count >= 2, SessionRecord.isValidSessionID(arguments[1]) else { return nil }
        let signal: AgentSignal
        switch arguments[0] {
        case "start": signal = .promptSubmitted
        case "heartbeat": signal = .activity
        case "wait": signal = .waitingForUser
        case "stop": signal = .idle
        case "end": signal = .sessionEnded
        default: return nil
        }
        return AgentEvent(agent: agent, sessionID: arguments[1], signal: signal, name: "generic.\(arguments[0])",
                          cwd: FileManager.default.currentDirectoryPath)
    }
}
