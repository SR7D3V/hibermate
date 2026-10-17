import Foundation

public struct SessionTimeouts: Equatable, Sendable {
    public var permissionWait: TimeInterval
    public var staleWindow: TimeInterval
    public var longToolWindow: TimeInterval

    public init(permissionWait: TimeInterval, staleWindow: TimeInterval,
                longToolWindow: TimeInterval = SafetyLimits.longToolWindow) {
        self.permissionWait = permissionWait
        self.staleWindow = staleWindow
        self.longToolWindow = longToolWindow
    }

    public init(_ limits: EffectiveLimits) {
        self.init(permissionWait: limits.permissionWait, staleWindow: limits.staleWindow)
    }
}

public enum SessionVerdict: Equatable, Sendable {
    case holding
    case notHolding(NotHoldingReason)
    /// The agent process is gone or the record can't be trusted; remove the file.
    case dead(DeadReason)

    public enum NotHoldingReason: String, Equatable, Sendable {
        case idle, permissionWaitExpired, backgroundStale
    }

    public enum DeadReason: String, Equatable, Sendable {
        case processExited, staleWorking, timestampInFuture, abandoned
    }
}

public struct EvaluatedSession: Equatable, Sendable {
    public var record: SessionRecord
    public var verdict: SessionVerdict
    public var holds: Bool { verdict == .holding }
}

/// Answers "is the agent process still alive?". Checks the PID and its start
/// time, so a PID reused by another process doesn't count.
public protocol ProcessLiveness {
    func isAlive(pid: Int32, startTime: Double?) -> Bool
}

/// Combines all sessions into one decision. The hold is wanted if ANY session
/// holds. Reference-counting by session ID means one session finishing never
/// releases another's hold.
public enum SessionAggregator {
    public static func evaluate(_ records: [SessionRecord], now: Double, liveness: ProcessLiveness,
                                timeouts t: SessionTimeouts) -> [EvaluatedSession] {
        records.map { EvaluatedSession(record: $0, verdict: verdict(for: $0, now: now, liveness: liveness, timeouts: t)) }
    }

    public static func holdWanted(_ sessions: [EvaluatedSession]) -> Bool {
        sessions.contains { $0.holds }
    }

    static func verdict(for r: SessionRecord, now: Double, liveness: ProcessLiveness, timeouts t: SessionTimeouts) -> SessionVerdict {
        if let pid = r.agentPID, !liveness.isAlive(pid: pid, startTime: r.agentStartTime) {
            return .dead(.processExited)
        }
        // A timestamp well in the future means the clock jumped or the file is
        // bogus. It can't be trusted for staleness, so drop it.
        if r.updatedAt > now + 300 { return .dead(.timestampInFuture) }
        let age = max(0, now - r.updatedAt)

        switch r.state {
        case .working:
            let window = r.toolsInFlight.isEmpty ? t.staleWindow : max(t.staleWindow, t.longToolWindow)
            return age > window ? .dead(.staleWorking) : .holding
        case .background:
            return age > t.staleWindow ? .notHolding(.backgroundStale) : .holding
        case .waiting:
            return now - r.stateSince > t.permissionWait ? .notHolding(.permissionWaitExpired) : .holding
        case .idle:
            // With no PID to check, an idle record that's untouched for a day is abandoned.
            if r.agentPID == nil, age > 24 * 3600 { return .dead(.abandoned) }
            return .notHolding(.idle)
        }
    }
}
