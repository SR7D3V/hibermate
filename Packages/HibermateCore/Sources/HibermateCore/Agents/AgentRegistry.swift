import Foundation

/// Every integration the hook binary understands.
public enum AgentRegistry {
    public static let parsers: [AgentID: AgentEventParser.Type] = [
        ClaudeCodeParser.agent: ClaudeCodeParser.self,
        GenericParser.agent: GenericParser.self,
    ]
}
