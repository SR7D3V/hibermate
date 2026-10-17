import Darwin
import Foundation

public struct ProcessInfoEntry: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    /// Seconds since 1970 when the process started.
    public var startTime: Double
}

public protocol ProcessTable: ProcessLiveness {
    func entry(for pid: Int32) -> ProcessInfoEntry?
}

extension ProcessTable {
    public func isAlive(pid: Int32, startTime: Double?) -> Bool {
        guard let entry = entry(for: pid) else { return false }
        // A different start time means the PID was reused by another process.
        if let startTime, abs(entry.startTime - startTime) > 1 { return false }
        return true
    }
}

/// Reads the kernel process table via `sysctl(KERN_PROC_PID)`. It spawns no
/// processes and needs no special permissions for the user's own processes.
public struct DarwinProcessTable: ProcessTable {
    public init() {}

    public func entry(for pid: Int32) -> ProcessInfoEntry? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let tv = info.kp_proc.p_starttime
        return ProcessInfoEntry(pid: pid, parentPID: info.kp_eproc.e_ppid, name: name,
                                startTime: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}

public enum AgentAncestry {
    /// Wrappers between Claude Code and the hook binary: hooks run via `sh -c`.
    static let wrapperNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "nice", "timeout"]

    /// Walks up from `start` (the hook's parent) and returns the first ancestor
    /// that isn't a shell or wrapper. That process is Claude Code (`claude` or
    /// `node`). `$PPID` alone isn't enough, because the parent may be `sh`.
    public static func findAgent(startingAt start: Int32, table: ProcessTable, maxHops: Int = 8) -> ProcessInfoEntry? {
        var pid = start
        for _ in 0..<maxHops {
            guard pid > 1, let entry = table.entry(for: pid) else { return nil }
            if !wrapperNames.contains(entry.name) { return entry }
            pid = entry.parentPID
        }
        return nil
    }
}
