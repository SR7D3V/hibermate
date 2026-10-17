import Foundation
import Testing
@testable import HibermateCore

@Suite("Hook runner on disk")
struct HookRunnerTests {
    func context(_ dir: URL, procs: FakeProcesses, now: Double = 1000) -> HookRunner.Context {
        HookRunner.Context(paths: HibermatePaths(supportDirectory: dir), now: now, parentPID: 70, processTable: procs)
    }

    func procs() -> FakeProcesses {
        let p = FakeProcesses()
        p.add(70, parent: 60, name: "sh")
        p.add(60, parent: 1, name: "claude", start: 123)
        return p
    }

    func input(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    @Test func writesSessionWithAgentPIDAndNoPromptText() throws {
        let dir = makeTempDir()
        let data = input(["hook_event_name": "UserPromptSubmit", "session_id": "abc-123",
                          "prompt": "SECRET PROMPT TEXT", "transcript_path": "/tmp/t.jsonl",
                          "cwd": "/Users/x/proj"])
        HookRunner.run(input: data, context: context(dir, procs: procs()))
        let file = dir.appendingPathComponent("sessions/claude-code/abc-123.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("SECRET"))
        #expect(!text.contains("transcript"))
        #expect(!text.contains("/Users/x"))
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(text.utf8))
        #expect(r.state == .working)
        #expect(r.agentPID == 60, "walked past the sh wrapper")
        #expect(r.agentStartTime == 123)
        #expect(r.project == "proj")
    }

    @Test func doesNothingWhenHibermateIsNotInstalled() {
        let dir = makeTempDir().appendingPathComponent("missing")
        let action = HookRunner.run(input: input(["hook_event_name": "UserPromptSubmit", "session_id": "a"]),
                                    context: context(dir, procs: procs()))
        #expect(action == .ignore)
        #expect(!FileManager.default.fileExists(atPath: dir.path), "must not create directories")
    }

    @Test(arguments: [Data(), Data("garbage".utf8), Data("[]".utf8), Data(#"{"hook_event_name":"Stop"}"#.utf8),
                      Data(#"{"hook_event_name":"Stop","session_id":"../../etc/passwd"}"#.utf8),
                      Data(#"{"hook_event_name":"Stop","session_id":""}"#.utf8)])
    func malformedInputIsIgnored(data: Data) throws {
        let dir = makeTempDir()
        #expect(HookRunner.run(input: data, context: context(dir, procs: procs())) == .ignore)
        #expect(SessionStore(paths: HibermatePaths(supportDirectory: dir)).loadAll().records.isEmpty)
    }

    @Test func sessionEndRemovesFile() throws {
        let dir = makeTempDir()
        let p = procs()
        HookRunner.run(input: input(["hook_event_name": "UserPromptSubmit", "session_id": "s"]), context: context(dir, procs: p))
        HookRunner.run(input: input(["hook_event_name": "SessionEnd", "session_id": "s"]), context: context(dir, procs: p))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions/claude-code/s.json").path))
    }

    @Test func agentArgumentSelectsParserAndSeparatesSessions() throws {
        let dir = makeTempDir()
        let p = procs()
        HookRunner.run(arguments: ["generic", "start", "same-id"], input: Data(), context: context(dir, procs: p))
        HookRunner.run(arguments: ["claude-code"], input: input(["hook_event_name": "Stop", "session_id": "same-id"]),
                       context: context(dir, procs: p))
        let records = SessionStore(paths: HibermatePaths(supportDirectory: dir)).loadAll().records
        #expect(Set(records.map(\.key)) == ["generic/same-id", "claude-code/same-id"])
        #expect(records.first { $0.agent == .generic }?.state == .working)
    }

    @Test func unknownAgentArgumentFallsBackToClaude() {
        #expect(HookRunner.parser(for: ["nope"]).0.agent == .claudeCode)
        #expect(HookRunner.parser(for: []).0.agent == .claudeCode)
        #expect(HookRunner.parser(for: ["generic", "start", "x"]).1 == ["start", "x"])
    }

    @Test func readOnlySessionsDirectoryFailsSilently() throws {
        let dir = makeTempDir()
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        chmod(sessions.path, 0o500)
        defer { chmod(sessions.path, 0o700) }
        // Must not crash or throw.
        _ = HookRunner.run(input: input(["hook_event_name": "UserPromptSubmit", "session_id": "s"]), context: context(dir, procs: procs()))
    }

    @Test func storeSkipsMalformedFilesAndCleansOldOnes() throws {
        let dir = makeTempDir()
        let paths = HibermatePaths(supportDirectory: dir)
        try FileManager.default.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true)
        let store = SessionStore(paths: paths)
        try store.save(SessionRecord(sessionID: "good", state: .working, event: "UserPromptSubmit", updatedAt: 1))
        let agentDir = paths.agentDirectory(.claudeCode)
        let bad = agentDir.appendingPathComponent("bad.json")
        try Data("{not json".utf8).write(to: bad)
        let mismatched = agentDir.appendingPathComponent("other.json")
        try JSONEncoder().encode(SessionRecord(sessionID: "good", state: .working, event: "x", updatedAt: 1)).write(to: mismatched)

        let result = store.loadAll()
        #expect(result.records.map(\.sessionID) == ["good"])
        #expect(result.malformed.count == 2)

        store.removeMalformed(result, now: Date(), olderThan: 3600)
        #expect(FileManager.default.fileExists(atPath: bad.path), "fresh malformed files are kept for now")
        store.removeMalformed(result, now: Date().addingTimeInterval(7200), olderThan: 3600)
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }
}

@Suite("Real process table")
struct DarwinProcessTableTests {
    @Test func currentProcessIsAliveAndStartTimeChecked() throws {
        let table = DarwinProcessTable()
        let me = try #require(table.entry(for: getpid()))
        #expect(table.isAlive(pid: getpid(), startTime: me.startTime))
        #expect(!table.isAlive(pid: getpid(), startTime: me.startTime - 1000))
        #expect(table.entry(for: getppid())?.pid == getppid())
    }

    @Test func nonexistentPIDIsDead() {
        #expect(!DarwinProcessTable().isAlive(pid: 999_999, startTime: nil))
    }
}
