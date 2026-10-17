import Foundation

// Parsers for hook-capable tools other than Claude Code. Sources and caveats
// are in docs/AGENTS.md (researched 2026-10-17). Every parser is defensive:
// it reads only IDs, event names, and the working directory, and returns nil
// for anything it doesn't recognize.
//
// For these tools the hook command passes the event name as the first
// argument (`hibermate-hook <agent> <Event>`), so detection doesn't depend on
// each tool's payload field names. The payload is used only for the session ID and cwd.

extension AgentID {
    public static let codex = AgentID(rawValue: "codex")!
    public static let gemini = AgentID(rawValue: "gemini")!
    public static let qwen = AgentID(rawValue: "qwen")!
    public static let copilot = AgentID(rawValue: "copilot")!
    public static let cursor = AgentID(rawValue: "cursor")!
    public static let opencode = AgentID(rawValue: "opencode")!
}

/// Shared helpers for JSON-on-stdin payloads.
enum Payload {
    static func object(_ data: Data) -> [String: Any] {
        guard !data.isEmpty, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }

    static func string(_ o: [String: Any], _ keys: String...) -> String? {
        for k in keys { if let s = o[k] as? String, !s.isEmpty { return s } }
        return nil
    }

    static func sessionID(_ o: [String: Any], _ keys: String...) -> String? {
        for k in keys {
            if let s = o[k] as? String, SessionRecord.isValidSessionID(s) { return s }
        }
        return nil
    }

    /// The event name: argv first, then the payload.
    static func eventName(_ arguments: [String], _ o: [String: Any]) -> String? {
        arguments.first ?? string(o, "hook_event_name", "hookEventName", "event")
    }
}

/// OpenAI Codex CLI lifecycle hooks (`~/.codex/hooks.json`).
public enum CodexParser: AgentEventParser {
    public static let agent = AgentID.codex
    public static let registeredEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Stop", "Interrupt", "SessionEnd",
    ]

    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        let o = Payload.object(stdin)
        guard let name = Payload.eventName(arguments, o), let id = Payload.sessionID(o, "session_id", "thread-id") else { return nil }
        let signal: AgentSignal
        switch name {
        case "SessionStart": signal = .sessionStarted(resetsWork: true)
        case "UserPromptSubmit": signal = .promptSubmitted
        case "PreToolUse", "PostToolUse": signal = .activity
        case "PermissionRequest": signal = .waitingForUser
        case "SubagentStart", "SubagentStop", "PreCompact", "PostCompact": signal = .heartbeat
        case "Stop": signal = .turnFinished(backgroundTasks: 0)
        case "Interrupt": signal = .idle // the user interrupted the turn
        case "SessionEnd": signal = .sessionEnded
        default: return nil
        }
        return AgentEvent(agent: agent, sessionID: id, signal: signal, name: name, cwd: Payload.string(o, "cwd"))
    }
}

/// Google Gemini CLI hooks (`~/.gemini/settings.json`).
public enum GeminiParser: AgentEventParser {
    public static let agent = AgentID.gemini
    public static let registeredEvents = [
        "SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "BeforeModel", "AfterModel",
        "Notification", "PreCompress", "AfterAgent", "SessionEnd",
    ]

    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        let o = Payload.object(stdin)
        let id = Payload.sessionID(o, "session_id") ?? ProcessInfo.processInfo.environment["GEMINI_SESSION_ID"]
            .flatMap { SessionRecord.isValidSessionID($0) ? $0 : nil }
        guard let name = Payload.eventName(arguments, o), let id else { return nil }
        let signal: AgentSignal
        switch name {
        case "SessionStart": signal = .sessionStarted(resetsWork: true)
        case "BeforeAgent": signal = .promptSubmitted
        case "BeforeTool", "AfterTool", "BeforeModel", "AfterModel": signal = .activity
        case "PreCompress": signal = .heartbeat
        case "Notification":
            guard Payload.string(o, "notification_type") == "ToolPermission" else { return nil }
            signal = .waitingForUser
        case "AfterAgent": signal = .turnFinished(backgroundTasks: 0)
        case "SessionEnd": signal = .sessionEnded
        default: return nil
        }
        return AgentEvent(agent: agent, sessionID: id, signal: signal, name: name,
                          cwd: Payload.string(o, "cwd") ?? ProcessInfo.processInfo.environment["GEMINI_CWD"])
    }
}

/// Qwen Code: Claude Code-compatible hooks (`~/.qwen/settings.json`).
public enum QwenParser: AgentEventParser {
    public static let agent = AgentID.qwen
    public static let registeredEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Notification", "SubagentStop", "PreCompact", "Stop", "SessionEnd",
    ]

    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        var o = Payload.object(stdin)
        if let name = arguments.first { o["hook_event_name"] = name }
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              var event = ClaudeCodeParser.parse(arguments: [], stdin: data) else { return nil }
        event.agent = agent
        return event
    }
}

/// GitHub Copilot CLI hooks (Hibermate's own file in `~/.copilot/hooks/`).
public enum CopilotParser: AgentEventParser {
    public static let agent = AgentID.copilot
    /// `preToolUse` is deliberately absent: it fails closed.
    public static let registeredEvents = [
        "sessionStart", "userPromptSubmitted", "postToolUse", "permissionRequest", "notification", "agentStop", "sessionEnd",
    ]

    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        let o = Payload.object(stdin)
        guard let name = Payload.eventName(arguments, o), let id = Payload.sessionID(o, "sessionId", "session_id") else { return nil }
        let signal: AgentSignal
        switch name {
        case "sessionStart": signal = .sessionStarted(resetsWork: true)
        case "userPromptSubmitted": signal = .promptSubmitted
        case "postToolUse": signal = .activity
        case "permissionRequest": signal = .waitingForUser
        case "notification":
            switch Payload.string(o, "notification_type", "notificationType") {
            case "permission_prompt", "elicitation_dialog": signal = .waitingForUser
            case "agent_idle", "agent_completed": signal = .idle
            default: return nil
            }
        case "agentStop": signal = .turnFinished(backgroundTasks: 0)
        case "sessionEnd": signal = .sessionEnded
        default: return nil
        }
        return AgentEvent(agent: agent, sessionID: id, signal: signal, name: name, cwd: Payload.string(o, "cwd"))
    }
}

/// Cursor hooks (`~/.cursor/hooks.json`), for both the IDE agent and the `agent`
/// CLI. Only non-permission events are used: an empty reply blocks permission hooks.
public enum CursorParser: AgentEventParser {
    public static let agent = AgentID.cursor
    public static let registeredEvents = [
        "sessionStart", "beforeSubmitPrompt", "postToolUse", "afterShellExecution", "afterFileEdit",
        "afterMCPExecution", "afterAgentResponse", "stop", "sessionEnd",
    ]

    /// What the shell wrapper prints for Cursor, which expects JSON on stdout.
    public static func reply(for event: String) -> String {
        event == "beforeSubmitPrompt" ? #"{"continue":true}"# : "{}"
    }

    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        let o = Payload.object(stdin)
        guard let name = Payload.eventName(arguments, o), let id = Payload.sessionID(o, "conversation_id", "session_id") else { return nil }
        let signal: AgentSignal
        switch name {
        case "sessionStart": signal = .sessionStarted(resetsWork: true)
        case "beforeSubmitPrompt": signal = .promptSubmitted
        case "postToolUse", "afterShellExecution", "afterFileEdit", "afterMCPExecution", "afterAgentResponse":
            signal = .activity
        case "stop": signal = .turnFinished(backgroundTasks: 0)
        case "sessionEnd": signal = .sessionEnded
        default: return nil
        }
        let cwd = (o["workspace_roots"] as? [String])?.first ?? ProcessInfo.processInfo.environment["CURSOR_PROJECT_DIR"]
        return AgentEvent(agent: agent, sessionID: id, signal: signal, name: name, cwd: cwd)
    }
}

/// OpenCode, via the small plugin Hibermate installs. The plugin forwards
/// `{"session_id", "status", "cwd"}` with the event type as the argument.
public enum OpenCodeParser: AgentEventParser {
    public static let agent = AgentID.opencode

    public static func parse(arguments: [String], stdin: Data) -> AgentEvent? {
        let o = Payload.object(stdin)
        guard let name = Payload.eventName(arguments, o), let id = Payload.sessionID(o, "session_id", "sessionID") else { return nil }
        let signal: AgentSignal
        switch name {
        case "session.status":
            switch Payload.string(o, "status") {
            case "busy": signal = .promptSubmitted
            case "retry": signal = .activity
            case "idle": signal = .idle
            default: return nil
            }
        case "session.idle", "session.error": signal = .idle
        case "permission.asked", "permission.updated", "question.asked": signal = .waitingForUser
        case "permission.replied", "tool.execute.before", "tool.execute.after", "message.part.updated": signal = .activity
        case "session.deleted": signal = .sessionEnded
        default: return nil
        }
        return AgentEvent(agent: agent, sessionID: id, signal: signal, name: name, cwd: Payload.string(o, "cwd"))
    }
}
