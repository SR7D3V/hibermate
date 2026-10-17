import Foundation
import Testing
@testable import HibermateCore

final class FakeProcesses: ProcessTable, @unchecked Sendable {
    var entries: [Int32: ProcessInfoEntry] = [:]

    func add(_ pid: Int32, parent: Int32, name: String, start: Double = 100) {
        entries[pid] = ProcessInfoEntry(pid: pid, parentPID: parent, name: name, startTime: start)
    }

    func kill9(_ pid: Int32) { entries[pid] = nil }

    func entry(for pid: Int32) -> ProcessInfoEntry? { entries[pid] }
}

/// Builds real Claude Code hook JSON and runs it through the parser.
private func ev(_ name: String, _ id: String = "s1", notification: String? = nil, source: String? = nil,
                bg: Int? = nil, tool: String? = nil, agent: String? = nil, cwd: String? = nil) -> AgentEvent {
    var o: [String: Any] = ["hook_event_name": name, "session_id": id, "prompt": "secret"]
    if let notification { o["notification_type"] = notification }
    if let source { o["source"] = source }
    if let bg { o["background_tasks"] = Array(repeating: ["id": "x"], count: bg) }
    if let tool { o["tool_use_id"] = tool }
    if let agent { o["agent_id"] = agent }
    if let cwd { o["cwd"] = cwd }
    let data = try! JSONSerialization.data(withJSONObject: o)
    return ClaudeCodeParser.parse(arguments: [], stdin: data)
        ?? AgentEvent(agent: .claudeCode, sessionID: id, signal: .heartbeat, name: "UNPARSED:\(name)")
}

/// Applies a sequence of events to one session record.
private func apply(_ events: [AgentEvent], start: SessionRecord? = nil, now: Double = 1000) -> SessionRecord? {
    var record = start
    var t = now
    for e in events {
        if e.name.hasPrefix("UNPARSED:") { t += 1; continue }
        switch SessionTransitions.nextAction(existing: record, event: e, now: t) {
        case .write(let r): record = r
        case .delete: record = nil
        case .ignore: break
        }
        t += 1
    }
    return record
}

@Suite("Claude Code hook event → session state")
struct HookMappingTests {
    @Test func promptMakesWorkingStopMakesIdle() {
        #expect(apply([ev("SessionStart"), ev("UserPromptSubmit")])?.state == .working)
        #expect(apply([ev("UserPromptSubmit"), ev("PostToolUse"), ev("Stop")])?.state == .idle)
    }

    @Test func stopFailureIsIdle() {
        #expect(apply([ev("UserPromptSubmit"), ev("StopFailure")])?.state == .idle)
    }

    @Test func sessionEndDeletes() {
        #expect(apply([ev("UserPromptSubmit"), ev("SessionEnd")]) == nil)
    }

    @Test func subagentStopIsHeartbeatOnly() {
        let r = apply([ev("UserPromptSubmit"), ev("SubagentStop")])
        #expect(r?.state == .working)
        #expect(r?.event == "SubagentStop")
        let idle = apply([ev("UserPromptSubmit"), ev("Stop"), ev("SubagentStop")])
        #expect(idle?.state == .idle, "a subagent finishing never re-marks idle as working")
    }

    @Test func toolEventsRefreshHeartbeat() {
        let r = apply([ev("UserPromptSubmit"), ev("PreToolUse", tool: "t1"), ev("PostToolUse", tool: "t1")], now: 1000)
        #expect(r?.updatedAt == 1002)
        #expect(r?.toolsInFlight == [])
    }

    @Test func toolsInFlightTracksParallelCalls() {
        let r = apply([ev("UserPromptSubmit"), ev("PreToolUse", tool: "a"), ev("PreToolUse", tool: "b"),
                       ev("PostToolUse", tool: "a")])
        #expect(r?.toolsInFlight == ["b"])
        #expect(apply([ev("UserPromptSubmit"), ev("PreToolUse", tool: "a"), ev("Stop")])?.toolsInFlight == [])
    }

    @Test func permissionRequestWaitsAndToolUseResumes() {
        #expect(apply([ev("UserPromptSubmit"), ev("PermissionRequest")])?.state == .waiting)
        #expect(apply([ev("UserPromptSubmit"), ev("PermissionRequest"), ev("PostToolUse")])?.state == .working)
    }

    @Test(arguments: ["permission_prompt", "elicitation_dialog", "agent_needs_input"])
    func waitingNotifications(type: String) {
        #expect(apply([ev("UserPromptSubmit"), ev("Notification", notification: type)])?.state == .waiting)
    }

    @Test func idlePromptNotificationIsIdle() {
        #expect(apply([ev("UserPromptSubmit"), ev("Notification", notification: "idle_prompt")])?.state == .idle)
    }

    @Test func otherNotificationsAreIgnored() {
        func parse(_ o: [String: Any]) -> AgentEvent? {
            ClaudeCodeParser.parse(arguments: [], stdin: try! JSONSerialization.data(withJSONObject: o))
        }
        #expect(parse(["hook_event_name": "Notification", "session_id": "s", "notification_type": "auth_success"]) == nil)
        #expect(parse(["hook_event_name": "Notification", "session_id": "s"]) == nil)
        #expect(parse(["hook_event_name": "CwdChanged", "session_id": "s"]) == nil)
    }

    @Test func parsedEventCarriesNoPromptText() {
        let e = ev("UserPromptSubmit", cwd: "/a/b")
        #expect(!String(describing: e).contains("secret"))
    }

    @Test func stopWithBackgroundTasksKeepsHolding() {
        let r = apply([ev("UserPromptSubmit"), ev("Stop", bg: 2)])
        #expect(r?.state == .background)
        #expect(r?.backgroundTaskCount == 2)
    }

    @Test func compactSessionStartDoesNotDropWork() {
        #expect(apply([ev("UserPromptSubmit"), ev("SessionStart", source: "compact")])?.state == .working)
        #expect(apply([ev("UserPromptSubmit"), ev("SessionStart", source: "clear")])?.state == .idle)
    }

    @Test func missedPromptRecoveredByMainThreadToolUse() {
        #expect(apply([ev("SessionStart"), ev("PreToolUse", tool: "x")])?.state == .working)
        #expect(apply([ev("SessionStart"), ev("PreToolUse", tool: "x", agent: "sub")])?.state == .idle)
    }

    @Test func storesOnlyFolderName() {
        let r = apply([ev("UserPromptSubmit", cwd: "/Users/someone/Documents/hibermate")])
        #expect(r?.project == "hibermate")
    }

    @Test func stateSinceChangesOnlyOnTransition() {
        let r = apply([ev("UserPromptSubmit"), ev("PermissionRequest"), ev("Notification", notification: "permission_prompt")], now: 1000)
        #expect(r?.stateSince == 1001)
    }
}

@Suite("Session liveness and aggregation")
struct AggregatorTests {
    let t = SessionTimeouts(permissionWait: 300, staleWindow: 900)

    func rec(_ id: String, _ state: SessionState, at: Double = 1000, since: Double? = nil, pid: Int32? = 50,
             tools: [String] = []) -> SessionRecord {
        SessionRecord(sessionID: id, state: state, event: "x", updatedAt: at, stateSince: since, agentPID: pid,
                      agentStartTime: 100, toolsInFlight: tools)
    }

    func processes() -> FakeProcesses {
        let p = FakeProcesses()
        p.add(50, parent: 1, name: "claude")
        p.add(60, parent: 1, name: "claude")
        return p
    }

    @Test func overlappingSessionsReferenceCount() {
        let p = processes()
        let a = rec("a", .working, pid: 50)
        var b = rec("b", .working, pid: 60)
        #expect(SessionAggregator.holdWanted(SessionAggregator.evaluate([a, b], now: 1010, liveness: p, timeouts: t)))
        b.state = .idle
        #expect(SessionAggregator.holdWanted(SessionAggregator.evaluate([a, b], now: 1010, liveness: p, timeouts: t)),
                "one session finishing doesn't release the other")
        let aIdle = rec("a", .idle)
        #expect(!SessionAggregator.holdWanted(SessionAggregator.evaluate([aIdle, b], now: 1010, liveness: p, timeouts: t)))
    }

    @Test func agentKilledWithKill9IsDead() {
        let p = processes()
        p.kill9(50)
        let e = SessionAggregator.evaluate([rec("a", .working)], now: 1001, liveness: p, timeouts: t)
        #expect(e[0].verdict == .dead(.processExited))
        #expect(!SessionAggregator.holdWanted(e))
    }

    @Test func pidReuseIsDetected() {
        let p = processes()
        p.add(50, parent: 1, name: "Safari", start: 999)
        #expect(SessionAggregator.evaluate([rec("a", .working)], now: 1001, liveness: p, timeouts: t)[0].verdict == .dead(.processExited))
    }

    @Test func lostStopEventGoesStaleAfterWindow() {
        let p = processes()
        #expect(SessionAggregator.evaluate([rec("a", .working)], now: 1000 + 899, liveness: p, timeouts: t)[0].holds)
        #expect(SessionAggregator.evaluate([rec("a", .working)], now: 1000 + 901, liveness: p, timeouts: t)[0].verdict == .dead(.staleWorking))
    }

    @Test func longRunningToolGetsLongerWindow() {
        let p = processes()
        let r = rec("a", .working, tools: ["build"])
        #expect(SessionAggregator.evaluate([r], now: 1000 + 1800, liveness: p, timeouts: t)[0].holds)
        #expect(!SessionAggregator.evaluate([r], now: 1000 + 3601, liveness: p, timeouts: t)[0].holds)
    }

    @Test func permissionWaitTimesOut() {
        let p = processes()
        let r = rec("a", .waiting, at: 1000, since: 1000)
        #expect(SessionAggregator.evaluate([r], now: 1299, liveness: p, timeouts: t)[0].holds)
        #expect(SessionAggregator.evaluate([r], now: 1301, liveness: p, timeouts: t)[0].verdict == .notHolding(.permissionWaitExpired))
    }

    @Test func backgroundHoldsUntilStale() {
        let p = processes()
        let r = rec("a", .background)
        #expect(SessionAggregator.evaluate([r], now: 1500, liveness: p, timeouts: t)[0].holds)
        #expect(SessionAggregator.evaluate([r], now: 2000, liveness: p, timeouts: t)[0].verdict == .notHolding(.backgroundStale))
    }

    @Test func futureTimestampIsUntrusted() {
        let p = processes()
        #expect(SessionAggregator.evaluate([rec("a", .working, at: 99_999)], now: 1000, liveness: p, timeouts: t)[0].verdict == .dead(.timestampInFuture))
    }

    @Test func sessionWithoutPIDStillGoesStale() {
        let p = processes()
        #expect(SessionAggregator.evaluate([rec("a", .working, pid: nil)], now: 3000, liveness: p, timeouts: t)[0].verdict == .dead(.staleWorking))
    }
}

@Suite("Queued prompts run to completion before sleep")
struct QueuedPromptTests {
    /// End-to-end: hook events → session records → aggregator → engine.
    @Test func queuedPromptsAcrossTwoSessionsHoldContinuously() {
        let p = FakeProcesses()
        p.add(50, parent: 1, name: "claude")
        p.add(60, parent: 1, name: "claude")
        let timeouts = SessionTimeouts(permissionWait: 300, staleWindow: 900)
        var records: [String: SessionRecord] = [:]
        var h = Harness()
        var allEffects: [Effect] = []

        func send(_ e: AgentEvent, pid: Int32) {
            if case .write(var r) = SessionTransitions.nextAction(existing: records[e.sessionID], event: e, now: h.now) {
                r.agentPID = pid
                r.agentStartTime = 100
                records[e.sessionID] = r
            }
            let evaluated = SessionAggregator.evaluate(Array(records.values), now: h.now, liveness: p, timeouts: timeouts)
            h.c.holdWanted = SessionAggregator.holdWanted(evaluated)
            allEffects += h.step()
        }

        // Session A has three queued prompts; session B has one long prompt.
        send(ev("UserPromptSubmit", "A"), pid: 50)
        send(ev("UserPromptSubmit", "B"), pid: 60)
        for _ in 0..<3 {
            allEffects += h.run(for: 120)
            send(ev("PostToolUse", "A"), pid: 50)
            allEffects += h.run(for: 60)
            send(ev("Stop", "A"), pid: 50)
            // Claude Code submits the next queued prompt a moment later.
            allEffects += h.run(for: 2, tick: 1)
            send(ev("UserPromptSubmit", "A"), pid: 50)
            send(ev("PostToolUse", "B"), pid: 60)
        }
        send(ev("Stop", "A"), pid: 50)
        #expect(allEffects == [.beginHold], "one continuous hold while any queued prompt remains")

        allEffects += h.run(for: 120)
        #expect(!allEffects.contains { if case .endHold = $0 { true } else { false } }, "B still working")

        send(ev("Stop", "B"), pid: 60)
        allEffects += h.run(for: 70)
        #expect(allEffects == [.beginHold, .endHold(.graceExpired), .sleepNow(.graceExpired)])
    }

    @Test func stopThenPromptWithinMinimumGraceNeverReleases() {
        var h = Harness()
        var s = UserSettings()
        s.gracePeriod = 1 // clamped to the 30 s floor
        h.limits = s.effectiveLimits(fanless: false)
        h.startHolding()
        h.c.holdWanted = false
        var effects = h.step()
        effects += h.run(for: 25, tick: 1)
        h.c.holdWanted = true
        effects += h.step()
        #expect(effects == [])
        #expect(h.engine.phase == .holding)
    }
}

@Suite("Generic integration")
struct GenericParserTests {
    @Test func startStopEnd() {
        func e(_ args: [String]) -> AgentEvent? { GenericParser.parse(arguments: args, stdin: Data()) }
        #expect(e(["start", "job-1"])?.signal == .promptSubmitted)
        #expect(e(["heartbeat", "job-1"])?.signal == .activity)
        #expect(e(["wait", "job-1"])?.signal == .waitingForUser)
        #expect(e(["stop", "job-1"])?.signal == .idle)
        #expect(e(["end", "job-1"])?.signal == .sessionEnded)
        #expect(e(["start"]) == nil)
        #expect(e(["start", "../x"]) == nil)
        #expect(e(["explode", "job-1"]) == nil)
        #expect(e(["start", "job-1"])?.agent == .generic)
    }

    @Test func agentIDValidation() {
        #expect(AgentID(rawValue: "claude-code") != nil)
        #expect(AgentID(rawValue: "Claude") == nil)
        #expect(AgentID(rawValue: "../x") == nil)
        #expect(AgentID(rawValue: "") == nil)
    }
}
