import Foundation

/// One process at one moment. CPU and GPU times are cumulative nanoseconds.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var parentName: String?
    public var name: String
    /// argv, read only for processes whose name could match an argv-based rule.
    public var arguments: [String]
    public var startTime: Double
    public var cpuTimeNs: UInt64
    /// nil when GPU accounting isn't available (Intel Macs, or the IORegistry layout changed).
    public var gpuTimeNs: UInt64?

    public init(pid: Int32, parentPID: Int32 = 1, parentName: String? = nil, name: String, arguments: [String] = [], startTime: Double = 0,
                cpuTimeNs: UInt64, gpuTimeNs: UInt64? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.parentName = parentName
        self.name = name
        self.arguments = arguments
        self.startTime = startTime
        self.cpuTimeNs = cpuTimeNs
        self.gpuTimeNs = gpuTimeNs
    }
}

/// Recognizes one tool's processes.
public struct ActivityRule: Sendable, Identifiable {
    public enum Kind: String, Sendable { case localModel, agentCLI }

    public var id: AgentID
    public var displayName: String
    public var kind: Kind
    /// Exact process names (`p_comm`, at most 16 characters).
    public var names: Set<String> = []
    /// Lowercased name prefixes, e.g. "python" matches "Python" and "python3.12".
    public var namePrefixes: [String] = []
    /// If set, some argv element must contain one of these.
    public var argvContainsAny: [String] = []
    /// If set, the parent process name must be one of these.
    public var parentNames: Set<String> = []

    public var needsArguments: Bool { !argvContainsAny.isEmpty }

    public func matches(_ p: ProcessSample, parentName: String?) -> Bool {
        let lower = p.name.lowercased()
        guard names.contains(p.name) || namePrefixes.contains(where: { lower.hasPrefix($0) }) else { return false }
        if !parentNames.isEmpty, !(parentName.map(parentNames.contains) ?? false) { return false }
        if !argvContainsAny.isEmpty {
            let argv = p.arguments.dropFirst()
            guard argvContainsAny.contains(where: { needle in argv.contains { $0.contains(needle) } }) else { return false }
        }
        return true
    }
}

/// Built-in rules. Process names come from source and docs research
/// (docs/AGENTS.md, 2026-10-17); LM Studio's are unconfirmed.
public enum ActivityCatalog {
    public static let rules: [ActivityRule] = [
        ActivityRule(id: AgentID(rawValue: "ollama")!, displayName: "Ollama", kind: .localModel,
                     names: ["ollama"], argvContainsAny: ["runner"]),
        ActivityRule(id: AgentID(rawValue: "ollama")!, displayName: "Ollama", kind: .localModel,
                     names: ["llama-server"], parentNames: ["ollama"]),
        ActivityRule(id: AgentID(rawValue: "llama-cpp")!, displayName: "llama.cpp", kind: .localModel,
                     names: ["llama-server", "llama-cli", "llama-mtmd-cli"]),
        ActivityRule(id: AgentID(rawValue: "mlx")!, displayName: "MLX", kind: .localModel,
                     namePrefixes: ["python"], argvContainsAny: ["mlx_lm", "mlx-lm", "mlx_vlm"]),
        ActivityRule(id: AgentID(rawValue: "vllm")!, displayName: "vLLM", kind: .localModel,
                     namePrefixes: ["python", "vllm"], argvContainsAny: ["vllm"]),
        ActivityRule(id: AgentID(rawValue: "lm-studio")!, displayName: "LM Studio", kind: .localModel,
                     names: ["llmster", "LM Studio Helper", "LM Studio"]),
        ActivityRule(id: AgentID(rawValue: "localai")!, displayName: "LocalAI", kind: .localModel,
                     names: ["local-ai"]),
        ActivityRule(id: AgentID(rawValue: "aider")!, displayName: "Aider", kind: .agentCLI,
                     names: ["aider"], namePrefixes: ["python"], argvContainsAny: ["aider"]),
        ActivityRule(id: AgentID(rawValue: "crush")!, displayName: "Crush", kind: .agentCLI, names: ["crush"]),
        ActivityRule(id: AgentID(rawValue: "amp")!, displayName: "Amp", kind: .agentCLI, names: ["amp"]),
        ActivityRule(id: AgentID(rawValue: "goose")!, displayName: "Goose", kind: .agentCLI, names: ["goose"]),
        ActivityRule(id: AgentID(rawValue: "droid")!, displayName: "Factory Droid", kind: .agentCLI, names: ["droid"]),
        ActivityRule(id: AgentID(rawValue: "kiro")!, displayName: "Kiro CLI", kind: .agentCLI, names: ["kiro-cli", "kiro"]),
    ]

    /// Rules grouped by tool, for the settings list.
    public static var tools: [(id: AgentID, displayName: String, kind: ActivityRule.Kind)] {
        var seen = Set<AgentID>()
        return rules.compactMap { r in seen.insert(r.id).inserted ? (r.id, r.displayName, r.kind) : nil }
    }

    /// Process names worth reading argv for (argv is read only for these).
    public static func argumentCandidate(_ name: String, rules: [ActivityRule]) -> Bool {
        let lower = name.lowercased()
        return rules.contains { $0.needsArguments && ($0.names.contains(name) || $0.namePrefixes.contains { lower.hasPrefix($0) }) }
    }

    public static func nameCandidate(_ name: String, rules: [ActivityRule]) -> Bool {
        let lower = name.lowercased()
        return rules.contains { $0.names.contains(name) || $0.namePrefixes.contains { lower.hasPrefix($0) } }
    }
}

/// Turns successive process samples into synthetic sessions. A matched process
/// is "working" while its CPU or GPU use exceeds a small threshold, and for
/// `quietPeriod` seconds after it last did. That bridges pauses between
/// requests or tokens.
public struct ActivityTracker: Sendable {
    /// Fraction of one CPU core.
    public var cpuThreshold = 0.05
    /// Fraction of wall time the GPU spent on this process.
    public var gpuThreshold = 0.05
    public var quietPeriod: TimeInterval = 90

    private var previous: [Int32: (sample: ProcessSample, at: TimeInterval)] = [:]
    private var lastActiveWall: [Int32: Double] = [:]

    public init() {}

    /// - Parameters:
    ///   - now: monotonic seconds, used for utilization deltas.
    ///   - wallNow: seconds since 1970, stored in the synthetic records.
    public mutating func update(samples: [ProcessSample], rules: [ActivityRule], now: TimeInterval, wallNow: Double) -> [SessionRecord] {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var records: [SessionRecord] = []
        var seen = Set<Int32>()

        for p in samples {
            let parentName = p.parentName ?? byPID[p.parentPID]?.name
            guard let rule = rules.first(where: { $0.matches(p, parentName: parentName) }) else { continue }
            // A llama-server under Ollama is reported once, as Ollama.
            seen.insert(p.pid)

            if let prev = previous[p.pid], prev.sample.startTime == p.startTime {
                let dt = now - prev.at
                if dt > 0.5 {
                    let cpu = Double(p.cpuTimeNs &- prev.sample.cpuTimeNs) / 1e9 / dt
                    var gpu = 0.0
                    if let g = p.gpuTimeNs, let pg = prev.sample.gpuTimeNs, g >= pg { gpu = Double(g - pg) / 1e9 / dt }
                    if cpu >= cpuThreshold || gpu >= gpuThreshold { lastActiveWall[p.pid] = wallNow }
                }
            }
            previous[p.pid] = (p, now)

            let active = lastActiveWall[p.pid].map { wallNow - $0 <= quietPeriod } ?? false
            records.append(SessionRecord(
                agent: rule.id, sessionID: "pid-\(p.pid)", state: active ? .working : .idle,
                event: active ? "activity" : "quiet", updatedAt: active ? wallNow : (lastActiveWall[p.pid] ?? wallNow),
                stateSince: lastActiveWall[p.pid] ?? wallNow, agentPID: p.pid, agentStartTime: p.startTime,
                project: rule.displayName))
        }
        // Forget processes that are gone.
        previous = previous.filter { seen.contains($0.key) }
        lastActiveWall = lastActiveWall.filter { seen.contains($0.key) }
        return records
    }
}
