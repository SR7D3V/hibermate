import Foundation
import Testing
@testable import HibermateCore

private func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

@Suite("Agent parsers")
struct AgentParserTests {
    @Test func codexMapsLifecycle() {
        let p = json(["session_id": "c1", "cwd": "/w/app", "prompt": "secret"])
        #expect(CodexParser.parse(arguments: ["UserPromptSubmit"], stdin: p)?.signal == .promptSubmitted)
        #expect(CodexParser.parse(arguments: ["PostToolUse"], stdin: p)?.signal == .activity)
        #expect(CodexParser.parse(arguments: ["PermissionRequest"], stdin: p)?.signal == .waitingForUser)
        #expect(CodexParser.parse(arguments: ["Stop"], stdin: p)?.signal == .turnFinished(backgroundTasks: 0))
        #expect(CodexParser.parse(arguments: ["Interrupt"], stdin: p)?.signal == .idle)
        #expect(CodexParser.parse(arguments: ["SessionEnd"], stdin: p)?.signal == .sessionEnded)
        #expect(CodexParser.parse(arguments: ["Stop"], stdin: p)?.cwd == "/w/app")
        #expect(CodexParser.parse(arguments: ["Stop"], stdin: Data()) == nil, "no session id")
        #expect(CodexParser.parse(arguments: ["Mystery"], stdin: p) == nil)
    }

    @Test func geminiMapsLifecycle() {
        let p = json(["session_id": "g1", "cwd": "/w/x"])
        #expect(GeminiParser.parse(arguments: ["BeforeAgent"], stdin: p)?.signal == .promptSubmitted)
        #expect(GeminiParser.parse(arguments: ["AfterModel"], stdin: p)?.signal == .activity)
        #expect(GeminiParser.parse(arguments: ["AfterAgent"], stdin: p)?.signal == .turnFinished(backgroundTasks: 0))
        let perm = json(["session_id": "g1", "notification_type": "ToolPermission"])
        #expect(GeminiParser.parse(arguments: ["Notification"], stdin: perm)?.signal == .waitingForUser)
        #expect(GeminiParser.parse(arguments: ["Notification"], stdin: p) == nil)
    }

    @Test func qwenReusesClaudeMappingUnderItsOwnID() {
        let e = QwenParser.parse(arguments: ["Stop"], stdin: json(["session_id": "q1"]))
        #expect(e?.agent == .qwen)
        #expect(e?.signal == .turnFinished(backgroundTasks: 0))
        #expect(QwenParser.parse(arguments: ["UserPromptSubmit"], stdin: json(["session_id": "q1"]))?.signal == .promptSubmitted)
    }

    @Test func copilotUsesCamelCaseSessionID() {
        let p = json(["sessionId": "cp1", "cwd": "/w"])
        #expect(CopilotParser.parse(arguments: ["userPromptSubmitted"], stdin: p)?.signal == .promptSubmitted)
        #expect(CopilotParser.parse(arguments: ["agentStop"], stdin: p)?.signal == .turnFinished(backgroundTasks: 0))
        let n = json(["sessionId": "cp1", "notification_type": "permission_prompt"])
        #expect(CopilotParser.parse(arguments: ["notification"], stdin: n)?.signal == .waitingForUser)
        #expect(!CopilotParser.registeredEvents.contains("preToolUse"), "preToolUse fails closed")
    }

    @Test func cursorUsesConversationIDAndWorkspaceRoot() {
        let p = json(["conversation_id": "cu1", "workspace_roots": ["/Users/x/site"]])
        let e = CursorParser.parse(arguments: ["beforeSubmitPrompt"], stdin: p)
        #expect(e?.signal == .promptSubmitted)
        #expect(e?.cwd == "/Users/x/site")
        #expect(CursorParser.parse(arguments: ["stop"], stdin: p)?.signal == .turnFinished(backgroundTasks: 0))
        for permissionEvent in ["preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "subagentStart"] {
            #expect(!CursorParser.registeredEvents.contains(permissionEvent), "\(permissionEvent) blocks on empty output")
        }
        #expect(CursorParser.reply(for: "beforeSubmitPrompt") == #"{"continue":true}"#)
        #expect(CursorParser.reply(for: "stop") == "{}")
    }

    @Test func openCodeStatusEvents() {
        func e(_ name: String, _ extra: [String: Any] = [:]) -> AgentEvent? {
            OpenCodeParser.parse(arguments: [name], stdin: json(["session_id": "o1"].merging(extra) { a, _ in a }))
        }
        #expect(e("session.status", ["status": "busy"])?.signal == .promptSubmitted)
        #expect(e("session.status", ["status": "idle"])?.signal == .idle)
        #expect(e("session.idle")?.signal == .idle)
        #expect(e("permission.asked")?.signal == .waitingForUser)
        #expect(e("session.deleted")?.signal == .sessionEnded)
        #expect(e("session.status", ["status": "weird"]) == nil)
    }

    @Test func everyRegisteredParserRejectsGarbage() {
        for (_, parser) in AgentRegistry.parsers {
            #expect(parser.parse(arguments: [], stdin: Data("garbage".utf8)) == nil)
            #expect(parser.parse(arguments: ["x", "../../etc"], stdin: json(["session_id": "../../etc"])) == nil)
        }
    }
}

@Suite("Hook config schemas for other tools")
struct HookConfigSchemaTests {
    @Test func commandsPassAgentAndEventAndStaySilent() {
        let c = HookConfigSchema.codex.command(for: "Stop")
        #expect(c.contains("\"$f\" codex Stop >/dev/null 2>&1;"))
        #expect(c.hasSuffix("exit 0"))
        #expect(HookConfigSchema.claudeCode.command(for: "Stop").contains("\"$f\" claude-code >/dev/null"))
    }

    @Test func cursorWrapperRepliesWithJSON() {
        let c = HookConfigSchema.cursor.command(for: "beforeSubmitPrompt")
        #expect(c.contains(#"printf '%s' '{"continue":true}'"#))
        #expect(HookConfigSchema.codex.command(for: "Stop").contains("printf") == false)
    }

    @Test func flatSchemaRoundTrip() throws {
        let original = #"{"version":1,"hooks":{"stop":[{"command":"./mine.sh"}]}}"#
        let root = try HookConfigMerger.parse(Data(original.utf8))
        let installed = try HookConfigMerger.install(into: root, schema: .cursor)
        guard case .array(let stops)? = installed["hooks"]?["stop"] else { Issue.record("no stop"); return }
        #expect(stops.count == 2)
        #expect(HookConfigMerger.containsOurs(installed, schema: .cursor))
        #expect(HookConfigMerger.removeOurs(from: installed, schema: .cursor) == root)
    }

    @Test func newFileGetsVersion() throws {
        let installed = try HookConfigMerger.install(into: .object([]), schema: .copilot, isNewFile: true)
        guard case .object(let members) = installed else { return }
        #expect(members.first?.key == "version")
        #expect(installed["hooks"]?["agentStop"] != nil)
    }

    @Test func geminiHandlerUsesMilliseconds() throws {
        let installed = try HookConfigMerger.install(into: .object([]), schema: .gemini)
        guard case .array(let groups)? = installed["hooks"]?["AfterAgent"],
              case .array(let handlers)? = groups.first?["hooks"] else { Issue.record("shape"); return }
        #expect(handlers.first?["timeout"] == .number("5000"))
        #expect(handlers.first?["name"] == .string("hibermate"))
    }

    @Test func ownedFileIsDeletedOnUninstall() throws {
        let dir = makeTempDir()
        let file = HookConfigFile(url: dir.appendingPathComponent("hooks/hibermate.json"), schema: .copilot,
                                  ownedFile: true, createsParentDirectory: true)
        try file.install()
        #expect(try file.isInstalled())
        try file.uninstall()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func ownedFileWithUserEditsIsKept() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("hibermate.json")
        let file = HookConfigFile(url: url, schema: .copilot, ownedFile: true)
        try file.install()
        // The user added their own hook to our file.
        var root = try HookConfigMerger.parse(try Data(contentsOf: url))
        guard case .object(var top) = root, let i = top.firstIndex(where: { $0.key == "hooks" }),
              case .object(var events) = top[i].value else { return }
        events.append(.init("custom", .array([.object([.init("bash", .string("echo hi"))])])))
        top[i].value = .object(events)
        root = .object(top)
        try OrderedJSONWriter().serialize(root).write(to: url)
        try file.uninstall()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try !file.isInstalled())
    }
}

@Suite("Relabeling hooks run by another tool")
struct RelabelTests {
    @Test func copilotRunningClaudeHooksIsFiledAsCopilot() throws {
        let dir = makeTempDir()
        let p = FakeProcesses()
        p.add(70, parent: 60, name: "bash")
        p.add(60, parent: 1, name: "copilot")
        let ctx = HookRunner.Context(paths: HibermatePaths(supportDirectory: dir), now: 1, parentPID: 70, processTable: p)
        HookRunner.run(arguments: ["claude-code"], input: json(["hook_event_name": "UserPromptSubmit", "session_id": "x"]), context: ctx)
        let records = SessionStore(paths: HibermatePaths(supportDirectory: dir)).loadAll().records
        #expect(records.map(\.agent) == [.copilot])
    }
}

@Suite("Activity watching (local LLMs and hookless tools)")
struct ActivityTrackerTests {
    let rules = ActivityCatalog.rules
    let second: UInt64 = 1_000_000_000

    @Test func idleLoadedModelDoesNotHoldButGeneratingDoes() {
        var t = ActivityTracker()
        var gpu: UInt64 = 0
        func step(_ at: Double, gpuDelta: UInt64) -> SessionRecord? {
            gpu += gpuDelta
            let s = ProcessSample(pid: 10, parentPID: 9, parentName: "ollama", name: "llama-server",
                                  startTime: 5, cpuTimeNs: 0, gpuTimeNs: gpu)
            return t.update(samples: [s], rules: rules, now: at, wallNow: 1000 + at).first
        }
        #expect(step(0, gpuDelta: 0)?.state == .idle)
        #expect(step(3, gpuDelta: 0)?.state == .idle, "loaded but idle")
        let r = step(6, gpuDelta: 2 * second) // GPU busy 2 s out of 3 s
        #expect(r?.state == .working)
        #expect(r?.agent.rawValue == "ollama", "llama-server under Ollama is reported as Ollama")
        #expect(step(60, gpuDelta: 0)?.state == .working, "within the quiet period")
        #expect(step(200, gpuDelta: 0)?.state == .idle, "quiet period over")
    }

    @Test func cpuActivityCountsWithoutGPU() {
        var t = ActivityTracker()
        let a = ProcessSample(pid: 20, name: "llama-cli", startTime: 1, cpuTimeNs: 0)
        _ = t.update(samples: [a], rules: rules, now: 0, wallNow: 0)
        var b = a
        b.cpuTimeNs = 3 * second // a full core for 3 s
        #expect(t.update(samples: [b], rules: rules, now: 3, wallNow: 3).first?.state == .working)
    }

    @Test func pidReuseResetsBaseline() {
        var t = ActivityTracker()
        _ = t.update(samples: [ProcessSample(pid: 30, name: "llama-cli", startTime: 1, cpuTimeNs: 100 * second)],
                     rules: rules, now: 0, wallNow: 0)
        let reused = ProcessSample(pid: 30, name: "llama-cli", startTime: 2, cpuTimeNs: 101 * second)
        #expect(t.update(samples: [reused], rules: rules, now: 3, wallNow: 3).first?.state == .idle)
    }

    @Test func argvRulesMatch() {
        let mlx = ProcessSample(pid: 1, name: "Python", arguments: ["python", "-m", "mlx_lm.server"], cpuTimeNs: 0)
        #expect(rules.first { $0.matches(mlx, parentName: nil) }?.id.rawValue == "mlx")
        let plain = ProcessSample(pid: 2, name: "Python", arguments: ["python", "script.py"], cpuTimeNs: 0)
        #expect(rules.first { $0.matches(plain, parentName: nil) } == nil, "ordinary Python isn't an AI tool")
        let runner = ProcessSample(pid: 3, name: "ollama", arguments: ["ollama", "runner", "--model", "x"], cpuTimeNs: 0)
        #expect(rules.first { $0.matches(runner, parentName: nil) }?.id.rawValue == "ollama")
        let serve = ProcessSample(pid: 4, name: "ollama", arguments: ["ollama", "serve"], cpuTimeNs: 0)
        #expect(rules.first { $0.matches(serve, parentName: nil) } == nil, "the idle server alone doesn't count")
    }

    @Test func syntheticSessionsFlowThroughTheSameSafetyPath() {
        var t = ActivityTracker()
        let p = FakeProcesses()
        p.add(40, parent: 1, name: "llama-cli", start: 1)
        _ = t.update(samples: [ProcessSample(pid: 40, name: "llama-cli", startTime: 1, cpuTimeNs: 0)], rules: rules, now: 0, wallNow: 0)
        let records = t.update(samples: [ProcessSample(pid: 40, name: "llama-cli", startTime: 1, cpuTimeNs: 3 * second)],
                               rules: rules, now: 3, wallNow: 3)
        let evaluated = SessionAggregator.evaluate(records, now: 3, liveness: p, timeouts: SessionTimeouts(permissionWait: 300, staleWindow: 900))
        #expect(SessionAggregator.holdWanted(evaluated))
        p.kill9(40)
        #expect(!SessionAggregator.holdWanted(SessionAggregator.evaluate(records, now: 4, liveness: p,
                                                                          timeouts: SessionTimeouts(permissionWait: 300, staleWindow: 900))))
    }

    @Test func realSamplerRunsWithoutRoot() {
        // Smoke test: a self-matching rule finds this test process.
        let me = DarwinProcessTable().entry(for: getpid())!
        let rule = ActivityRule(id: AgentID(rawValue: "self")!, displayName: "Self", kind: .agentCLI, names: [me.name])
        let samples = DarwinProcessSampler().sample(rules: [rule], gpu: NoGPUTime())
        let mine = samples.first { $0.pid == getpid() }
        #expect(mine != nil)
        #expect((mine?.cpuTimeNs ?? 0) > 0)
    }
}

@Suite("Uninstall removes every integration")
struct IntegrationLocationsTests {
    @Test func installAllThenRemoveAllRestoresEveryFile() throws {
        let home = makeTempDir()
        let fm = FileManager.default
        // Pre-existing user configs for some tools; others don't exist yet.
        let originals: [String: String] = [
            ".claude/settings.json": #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine.sh"}]}]}}"# + "\n",
            ".cursor/hooks.json": #"{"version":1,"hooks":{"stop":[{"command":"./theirs.sh"}]}}"# + "\n",
            ".gemini/settings.json": #"{"theme":"dark"}"# + "\n",
        ]
        for (path, text) in originals {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for d in [".codex", ".qwen", ".copilot"] {
            try fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }

        let locations = IntegrationLocations.hookFiles(home: home)
        for l in locations { try l.file.install() }
        for l in locations { #expect(try l.file.isInstalled(), "\(l.displayName) installed") }

        let report = IntegrationLocations.removeAll(home: home)
        #expect(report.failed.isEmpty)
        #expect(report.removed.count == locations.count)
        for (path, text) in originals {
            #expect(try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) == text, "\(path) restored")
        }
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".copilot/hooks/hibermate.json").path))
        #expect(IntegrationLocations.removeAll(home: home).removed.isEmpty, "second run is a no-op")
    }

    @Test func openCodePluginRemovedOnlyIfOurs() throws {
        let home = makeTempDir()
        let plugin = IntegrationLocations.openCodePlugin(home: home)
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// someone else's plugin\n".utf8).write(to: plugin)
        #expect(IntegrationLocations.removeAll(home: home).removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: plugin.path))
        try Data((IntegrationLocations.openCodePluginHeader + " …\n").utf8).write(to: plugin)
        #expect(IntegrationLocations.removeAll(home: home).removed == ["OpenCode"])
    }

    @Test func corruptFileIsReportedNotTouched() throws {
        let home = makeTempDir()
        let url = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: url)
        let report = IntegrationLocations.removeAll(home: home)
        #expect(report.failed.map(\.name) == ["Claude Code"])
        #expect(try String(contentsOf: url, encoding: .utf8) == "{broken")
    }
}
