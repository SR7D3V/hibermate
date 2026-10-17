import AppKit
import Foundation
import HibermateCore

/// What the menu shows. Rebuilt on every tick.
struct MenuSnapshot: Equatable {
    enum Icon: Equatable { case idle, holding, grace, warning, setupNeeded }

    struct SessionRow: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String
    }

    var icon: Icon = .idle
    var headline = "Starting…"
    var sessions: [SessionRow] = []
    var thermal = ""
    var battery = ""
    var timeRemaining: String?
    var warnings: [String] = []
    var isActive = false
    var isPaused = false
}

enum SetupState: Equatable {
    case wrongLocation
    case helperNotRegistered
    case helperNeedsApproval
    case helperUnreachable
    case ready
}

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var snapshot = MenuSnapshot()
    @Published private(set) var setup: SetupState = .helperNotRegistered
    @Published var settings: UserSettings { didSet { saveSettings() } }

    let dryRun: Bool
    let paths = HibermatePaths()
    let integrations: [AgentIntegration]

    private var engine = HoldEngine()
    private let sensors: SystemSensing
    private let power: PowerActions
    private let store: SessionStore
    private let processes = DarwinProcessTable()
    private let fanless: Bool
    private var helperReachable = false
    private var lastHeartbeat: TimeInterval = -.infinity
    private var timer: Timer?
    private var lastConditions = Conditions()
    private var activity = ActivityTracker()
    private let sampler = DarwinProcessSampler()
    private let gpuTime = IORegistryGPUTime()

    init(dryRun: Bool) {
        self.dryRun = dryRun
        self.sensors = LiveSensors()
        self.power = dryRun ? DryRunPowerActions() : HelperPowerActions()
        self.store = SessionStore(paths: paths)
        self.fanless = ModelCooling.isFanless(LiveSensors().modelIdentifier())
        self.settings = Self.loadSettings(paths: paths)
        self.integrations = IntegrationCatalog.all(paths: paths, dryRun: dryRun)
        try? FileManager.default.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        appLog.notice("Hibermate starting (dry-run: \(dryRun, privacy: .public), fanless: \(self.fanless, privacy: .public))")
    }

    var limits: EffectiveLimits { settings.effectiveLimits(fanless: fanless) }
    var isFanless: Bool { fanless }

    func start() {
        refreshSetup()
        // Reconcile on launch: if a previous run crashed mid-hold, the helper
        // restores (and does nothing if no hold is recorded).
        if setup == .ready || dryRun { power.endHold { _ in } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    // MARK: - Setup

    func refreshSetup() {
        if dryRun {
            setup = .ready
            helperReachable = true
            return
        }
        guard AppLocation.isInApplications else { setup = .wrongLocation; return }
        switch HelperRegistration.status {
        case .enabled: setup = helperReachable ? .ready : .helperUnreachable
        case .requiresApproval: setup = .helperNeedsApproval
        case .notRegistered, .notFound, .unknown: setup = .helperNotRegistered
        }
    }

    func registerHelper() {
        guard !dryRun, AppLocation.isInApplications else { return }
        do {
            try HelperRegistration.register()
        } catch {
            appLog.error("Helper registration failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshSetup()
        pingHelper()
    }

    private func pingHelper() {
        guard HelperRegistration.status == .enabled || dryRun else {
            helperReachable = false
            return
        }
        power.heartbeat { [weak self] reachable, holdActive in
            guard let self else { return }
            self.helperReachable = reachable
            self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            // The helper restored on its own (e.g. a dropped connection) while
            // we're still holding: ask again.
            if reachable, !holdActive, self.engine.phase != .idle {
                self.power.beginHold { _ in }
            }
            self.refreshSetup()
        }
    }

    // MARK: - Tick

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let wall = Date()

        // Sessions from hooks, plus synthetic sessions from activity watching.
        let loaded = store.loadAll()
        store.removeMalformed(loaded, now: wall, olderThan: limits.staleWindow)
        let watched = Set(settings.watchedTools)
        let rules = ActivityCatalog.rules.filter { watched.contains($0.id.rawValue) }
        let watchedRecords = rules.isEmpty ? [] : activity.update(
            samples: sampler.sample(rules: rules, gpu: gpuTime), rules: rules, now: now, wallNow: wall.timeIntervalSince1970)
        let evaluated = SessionAggregator.evaluate(loaded.records + watchedRecords, now: wall.timeIntervalSince1970,
                                                   liveness: processes, timeouts: SessionTimeouts(limits))
        for s in evaluated { if case .dead = s.verdict { store.remove(s.record.agent, s.record.sessionID) } }
        let live = evaluated.filter { if case .dead = $0.verdict { false } else { true } }

        // Heartbeat: every 30 s while a hold is active, every 60 s otherwise.
        if now - lastHeartbeat >= (engine.isActive ? 30 : 60) { pingHelper() }

        let c = Conditions(
            holdWanted: SessionAggregator.holdWanted(live),
            helperReady: setup == .ready && helperReachable,
            appLocationOK: dryRun || AppLocation.isInApplications,
            thermal: sensors.thermal(),
            lidClosed: sensors.lidClosed(),
            externalDisplayConnected: sensors.externalDisplayConnected(),
            otherSleepAssertions: sensors.otherSleepAssertions(excluding: [getpid()]),
            power: sensors.power(),
            lowPowerMode: sensors.lowPowerMode()
        )
        lastConditions = c
        run(engine.update(now: now, conditions: c, limits: limits))
        snapshot = makeSnapshot(now: now, conditions: c, sessions: live)
    }

    private func didWake() {
        // Reconcile after wake: if we aren't holding, make sure nothing is left disabled.
        if !engine.isActive { power.endHold { _ in } }
        pingHelper()
        tick()
    }

    // MARK: - Commands

    func releaseNow() { command(.releaseNow) }
    func pauseOneHour() { command(.pause(until: ProcessInfo.processInfo.systemUptime + 3600)) }
    func resume() { command(.resume) }

    private func command(_ cmd: UserCommand) {
        run(engine.handle(cmd, now: ProcessInfo.processInfo.systemUptime, conditions: lastConditions))
        tick()
    }

    /// Releases everything, then calls `done` (used on quit and uninstall).
    func shutdown(_ done: @escaping () -> Void) {
        timer?.invalidate()
        let effects = engine.handle(.quit, now: ProcessInfo.processInfo.systemUptime, conditions: lastConditions)
        if effects.isEmpty {
            done()
        } else {
            run(effects, completion: done)
        }
    }

    // MARK: - Effects

    /// Runs effects strictly in order. `sleepNow` waits until the restore has
    /// finished, so sleep is never requested while SleepDisabled is still set.
    private func run(_ effects: [Effect], completion: (() -> Void)? = nil) {
        guard !effects.isEmpty else { completion?(); return }
        var queue = effects
        func next() {
            guard !queue.isEmpty else { completion?(); return }
            let effect = queue.removeFirst()
            switch effect {
            case .beginHold:
                appLog.notice("Hold started")
                power.beginHold { [weak self] ok in
                    guard let self else { return }
                    if !ok {
                        appLog.error("Helper refused to start the hold; failing safe")
                        self.helperReachable = false
                        self.run(self.engine.handle(.helperFailed, now: ProcessInfo.processInfo.systemUptime,
                                                    conditions: self.lastConditions))
                    }
                    next()
                }
            case .endHold(let reason):
                appLog.notice("Hold ended: \(reason.rawValue, privacy: .public)")
                power.endHold { _ in next() }
            case .sleepNow(let reason):
                appLog.notice("Sleeping the Mac: \(reason.rawValue, privacy: .public)")
                power.sleepNow()
                next()
            case .notifySafetyRelease(let reason, let slept):
                logSafetyRelease(reason, slept: slept)
                if settings.notificationsEnabled { Notifier.post(reason, slept: slept) }
                next()
            }
        }
        next()
    }

    private func logSafetyRelease(_ reason: ReleaseReason, slept: Bool) {
        let c = lastConditions
        let battery: String = switch c.power {
        case .ac: "AC"
        case .battery(let p): "\(p)%"
        case .unknown: "unknown"
        }
        appLog.notice("""
            Safety release: \(reason.rawValue, privacy: .public), slept: \(slept, privacy: .public), \
            thermal: \(String(describing: c.thermal), privacy: .public), battery: \(battery, privacy: .public), \
            lid closed: \(String(describing: c.lidClosed), privacy: .public)
            """)
    }

    // MARK: - Snapshot

    private func makeSnapshot(now: TimeInterval, conditions c: Conditions, sessions: [EvaluatedSession]) -> MenuSnapshot {
        var s = MenuSnapshot()
        s.isActive = engine.isActive
        s.isPaused = engine.pausedUntil != nil
        s.thermal = "Temperature: \(c.thermal.plainDescription)"
        s.battery = switch c.power {
        case .ac: "Power: plugged in"
        case .battery(let p): "Battery: \(p)%"
        case .unknown: "Battery: unknown"
        }
        if let left = engine.timeRemaining(now: now, conditions: c, limits: limits) {
            s.timeRemaining = "Max hold ends in \(Self.format(left))"
        }

        let wall = Date().timeIntervalSince1970
        s.sessions = sessions.sorted { $0.record.key < $1.record.key }.map { e in
            let r = e.record
            let agent = integrations.first { $0.id == r.agent }?.displayName
                ?? ActivityCatalog.tools.first { $0.id == r.agent }.map { "\($0.displayName) (activity)" }
                ?? r.agent.rawValue
            let state: String = switch (r.state, e.verdict) {
            case (_, .notHolding(.permissionWaitExpired)): "waiting for you (timed out)"
            case (.working, _): "working"
            case (.waiting, _): "waiting for you"
            case (.background, _): "background tasks"
            case (.idle, _): "idle"
            }
            return .init(id: r.key, title: "\(r.project ?? agent) — \(state)",
                         detail: "\(agent) · \(Self.format(max(0, wall - r.stateSince)))")
        }

        if sensors.batteryNeedsService() { s.warnings.append("Battery service recommended") }
        if let latched = engine.latchedReason {
            s.warnings.append("Paused for safety: \(latched.notificationBody(slept: false)) Open the lid to re-arm.")
        }

        switch setup {
        case .wrongLocation:
            s.icon = .setupNeeded; s.headline = "Move Hibermate to Applications"
        case .helperNotRegistered:
            s.icon = .setupNeeded; s.headline = "Setup needed"
        case .helperNeedsApproval:
            s.icon = .setupNeeded; s.headline = "Approve Hibermate in Login Items"
        case .helperUnreachable:
            s.icon = .warning; s.headline = "Helper not responding"
        case .ready:
            switch engine.phase {
            case .holding:
                s.icon = .holding; s.headline = "Keeping your Mac awake — safe to close the lid"
            case .grace(let until):
                s.icon = .grace; s.headline = "Work finished — sleeping in \(Self.format(max(0, until - now)))"
            case .idle:
                if engine.latchedReason != nil {
                    s.icon = .warning; s.headline = "Released for safety"
                } else if s.isPaused {
                    s.icon = .idle; s.headline = "Paused"
                } else {
                    s.icon = .idle; s.headline = "No agents working"
                }
            }
        }
        if dryRun { s.headline = "[Dry run] " + s.headline }
        return s
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    // MARK: - Settings persistence

    private static func loadSettings(paths: HibermatePaths) -> UserSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let s = try? JSONDecoder().decode(UserSettings.self, from: data) else { return UserSettings() }
        return s
    }

    private func saveSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try? AtomicFile.write(data, to: paths.settingsFile)
    }
}
