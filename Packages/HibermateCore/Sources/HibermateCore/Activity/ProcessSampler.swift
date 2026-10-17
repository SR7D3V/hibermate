import Darwin
import Foundation

/// Reports per-process GPU time in nanoseconds. The real implementation (in
/// the app) reads the IORegistry. When unavailable it returns an empty map,
/// and the tracker falls back to CPU only.
public protocol GPUTimeSource {
    func gpuTimeByPID() -> [Int32: UInt64]
}

public struct NoGPUTime: GPUTimeSource {
    public init() {}
    public func gpuTimeByPID() -> [Int32: UInt64] { [:] }
}

/// Lists the current user's processes that could match an activity rule, using
/// only libproc and sysctl. No root and no spawned processes.
public struct DarwinProcessSampler {
    private let table = DarwinProcessTable()
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public init() {}

    public func sample(rules: [ActivityRule], gpu: GPUTimeSource) -> [ProcessSample] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }

        let uid = getuid()
        let gpuTimes = gpu.gpuTimeByPID()
        var samples: [ProcessSample] = []
        var candidates: [ProcessInfoEntry] = []
        var parents: [Int32: ProcessInfoEntry] = [:]

        for pid in pids.prefix(Int(n)) where pid > 0 {
            guard let entry = table.entry(for: pid) else { continue }
            parents[pid] = entry
            guard ActivityCatalog.nameCandidate(entry.name, rules: rules), Self.owner(of: pid) == uid else { continue }
            candidates.append(entry)
        }
        for entry in candidates {
            guard let cpu = Self.cpuTimeNs(entry.pid) else { continue }
            let args = ActivityCatalog.argumentCandidate(entry.name, rules: rules) ? Self.arguments(of: entry.pid) : []
            let parentName = parents[entry.parentPID]?.name ?? table.entry(for: entry.parentPID)?.name
            samples.append(ProcessSample(pid: entry.pid, parentPID: entry.parentPID, parentName: parentName, name: entry.name,
                                         arguments: args, startTime: entry.startTime, cpuTimeNs: cpu,
                                         gpuTimeNs: gpuTimes[entry.pid]))
        }
        return samples
    }

    static func owner(of pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }

    static func cpuTimeNs(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
        }
        guard ok else { return nil }
        // rusage times are in Mach absolute-time units on Apple silicon.
        let ticks = usage.ri_user_time + usage.ri_system_time
        return ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    /// argv via `sysctl(KERN_PROCARGS2)`. It is readable only for the
    /// current user's own processes.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 } // exec path
        while i < size, buffer[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
