import Foundation

/// What the `hibermate-hook` binary does with one hook invocation. It never
/// throws and never prints. The binary always exits 0 regardless.
public enum HookRunner {
    public struct Context {
        public var paths: HibermatePaths
        public var now: Double
        public var parentPID: Int32
        public var processTable: ProcessTable

        public init(paths: HibermatePaths, now: Double, parentPID: Int32, processTable: ProcessTable) {
            self.paths = paths
            self.now = now
            self.parentPID = parentPID
            self.processTable = processTable
        }
    }

    @discardableResult
    public static func run(input: Data, context: Context) -> RecordAction {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // Not set up, or uninstalled: do nothing, and don't create directories.
        guard fm.fileExists(atPath: context.paths.supportDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return .ignore
        }
        guard let event = HookEvent.parse(input) else { return .ignore }

        try? fm.createDirectory(at: context.paths.sessionsDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Parallel tool calls can fire hooks concurrently. Serialize the
        // read-modify-write with a short, bounded lock wait (~40 ms) so the
        // hook stays fast even if the lock is stuck.
        let lockFD = open(context.paths.sessionsDirectory.appendingPathComponent(".lock").path,
                          O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { if lockFD >= 0 { close(lockFD) } }
        if lockFD >= 0 {
            for _ in 0..<20 where flock(lockFD, LOCK_EX | LOCK_NB) != 0 { usleep(2_000) }
        }

        let store = SessionStore(paths: context.paths)
        let existing = store.load(event.sessionID)
        let action = HookEventMapping.nextAction(existing: existing, event: event, now: context.now)

        switch action {
        case .ignore:
            break
        case .delete:
            store.remove(event.sessionID)
        case .write(var record):
            if record.agentPID == nil || !context.processTable.isAlive(pid: record.agentPID!, startTime: record.agentStartTime) {
                if let agent = AgentAncestry.findAgent(startingAt: context.parentPID, table: context.processTable) {
                    record.agentPID = agent.pid
                    record.agentStartTime = agent.startTime
                }
            }
            try? store.save(record)
            return .write(record)
        }
        return action
    }
}
