import Foundation

public enum RecordAction: Equatable, Sendable {
    case write(SessionRecord)
    case delete
    case ignore
}

/// Applies a normalized `AgentEvent` to a session record. The same rules apply
/// to every integration.
public enum SessionTransitions {
    static let maxToolsInFlight = 64

    public static func nextAction(existing: SessionRecord?, event e: AgentEvent, now: Double) -> RecordAction {
        var r = existing ?? SessionRecord(agent: e.agent, sessionID: e.sessionID, state: .idle, event: e.name, updatedAt: now)
        let previousState = r.state

        switch e.signal {
        case .sessionEnded:
            return .delete

        case .sessionStarted(let resetsWork):
            if resetsWork {
                r.state = .idle
                r.toolsInFlight = []
                r.backgroundTaskCount = 0
            }

        case .promptSubmitted:
            // Also fires for turns the agent starts by itself, e.g. the next queued prompt.
            r.state = .working
            r.toolsInFlight = []

        case .toolStarted(let id):
            if let id, !r.toolsInFlight.contains(id), r.toolsInFlight.count < maxToolsInFlight {
                r.toolsInFlight.append(id)
            }
            r.state = activityState(from: r.state, isSubagent: e.isSubagent)

        case .toolFinished(let id):
            if let id { r.toolsInFlight.removeAll { $0 == id } }
            r.state = activityState(from: r.state, isSubagent: e.isSubagent)

        case .activity:
            r.state = activityState(from: r.state, isSubagent: e.isSubagent)

        case .heartbeat:
            // Never marks an idle session working (e.g. a subagent finishing).
            if r.state == .waiting { r.state = .working }

        case .waitingForUser:
            r.state = .waiting

        case .turnFinished(let background):
            r.backgroundTaskCount = background
            r.state = background > 0 ? .background : .idle
            r.toolsInFlight = []

        case .idle:
            r.state = .idle
            r.toolsInFlight = []
            r.backgroundTaskCount = 0
        }

        r.event = e.name
        r.updatedAt = now
        if r.state != previousState || existing == nil { r.stateSince = now }
        if let project = SessionRecord.projectName(fromCWD: e.cwd) { r.project = project }
        return .write(r)
    }

    /// A tool running means work is happening, and that any pending permission
    /// was answered. Main-thread activity while "idle" means a prompt event was
    /// missed. Subagent activity while idle is covered by background-task counts instead.
    private static func activityState(from state: SessionState, isSubagent: Bool) -> SessionState {
        switch state {
        case .working, .waiting: .working
        case .background: .background
        case .idle: isSubagent ? .idle : .working
        }
    }
}
