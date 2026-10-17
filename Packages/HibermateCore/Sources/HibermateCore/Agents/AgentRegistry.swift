import Foundation

/// Every integration the hook binary understands.
public enum AgentRegistry {
    public static let parsers: [AgentID: AgentEventParser.Type] = [
        ClaudeCodeParser.agent: ClaudeCodeParser.self,
        CodexParser.agent: CodexParser.self,
        GeminiParser.agent: GeminiParser.self,
        QwenParser.agent: QwenParser.self,
        CopilotParser.agent: CopilotParser.self,
        CursorParser.agent: CursorParser.self,
        OpenCodeParser.agent: OpenCodeParser.self,
        GenericParser.agent: GenericParser.self,
    ]

    /// Some tools run other tools' hook files. For example, Copilot CLI also
    /// executes hooks from `.claude/settings.json`. Sessions are relabeled by
    /// the process that actually ran the hook.
    public static let relabelByProcessName: [String: AgentID] = [
        "copilot": .copilot,
        "qwen": .qwen,
        "droid": AgentID(rawValue: "droid")!,
    ]
}
