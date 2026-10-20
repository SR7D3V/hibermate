import AppKit
import Foundation
import HibermateCore

/// What the menu shows. Rebuilt on every tick.
struct MenuSnapshot: Equatable {
    enum Icon: Equatable { case idle, holding, grace, warning, setupNeeded }

    struct SessionRow: Equatable, Identifiable {
        enum Status: Equatable { case working, waiting, background, idle, timedOut }
        var id: String
        var agent: AgentID
        var agentName: String
        var project: String
        var status: Status
        var elapsed: String
        var holds: Bool

        var title: String { "\(project) — \(statusText.lowercased())" }
        var detail: String { "\(agentName) · \(elapsed)" }
        var statusText: String {
            switch status {
            case .working: "Working"
            case .waiting: "Waiting for you"
            case .background: "Background"
            case .idle: "Idle"
            case .timedOut: "Waiting (timed out)"
            }
        }
    }

    var icon: Icon = .idle
    var headline = "Starting…"
    /// Short line under the headline in the menu bar panel.
    var subtitle = ""
    var thermalLevel: ThermalLevel = .nominal
    /// e.g. "96%" or "Charging"; for the compact chips.
    var batteryShort = ""
    var timeLeftShort: String?
    /// One plain sentence explaining the headline, for the main window.
    var explanation = ""
    var sessions: [SessionRow] = []
    var thermal = ""
    var battery = ""
    var timeRemaining: String?
    var lid = ""
    var display = ""
    var otherApps = ""
    var warnings: [String] = []
    /// Newest first, for the window; the menu shows only the latest one.
    var recentReleases: [SafetyReleaseRecord] = []
    /// nil = not checked yet.
    var notificationsAllowed: Bool?
    var isActive = false
    var isPaused = false
}

/// The pages of Hibermate's window.
enum MainPage: String, CaseIterable, Identifiable, Hashable {
    case overview, agents, safety, general, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Status"
        case .agents: "AI Tools"
        case .safety: "Safety"
        case .general: "General"
        case .about: "About"
        }
    }
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
    /// The page Hibermate's window shows; the menu bar panel can jump to one.
    @Published var page: MainPage = .overview
    @Published private(set) var enabledIntegrations: Set<AgentID> = []
    @Published var integrationError: String?
    private var history: SafetyReleaseHistory
    private var notificationsAllowed: Bool?
    private var lastNotificationCheck: TimeInterval = -.infinity

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
    private var appNapOptOut: NSObjectProtocol?
    private var triedReregister = false
    private var lastSessionStatus: [String: String] = [:]
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
        self.history = SafetyReleaseHistory(file: HibermatePaths().safetyReleasesFile)
        self.integrations = IntegrationCatalog.all(paths: paths, dryRun: dryRun)
        try? FileManager.default.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        appLog.notice("Hibermate starting (dry-run: \(dryRun, privacy: .public), fanless: \(self.fanless, privacy: .public))")
    }

    var limits: EffectiveLimits { settings.effectiveLimits(fanless: fanless) }
    var isFanless: Bool { fanless }

    func start() {
        refreshSetup()
        refreshIntegrations()
        if !dryRun { HookBinaryInstaller.refreshIfOutdated(paths: paths) }
        // Re-registering after an update happens in pingHelper(), and only if
        // the helper doesn't respond, so an approval that's still valid is
        // never thrown away.
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
        // Opt out of App Nap. With the lid closed and the display off, macOS
        // throttled this menu bar app's timers, the 30 s heartbeat stopped, and
        // the helper's dead-man switch ended the hold after 2 min (seen on real
        // hardware, 2026-10-17). This doesn't prevent sleep; the hold itself does.
        appNapOptOut = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Hibermate monitors AI sessions and hardware safety")
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
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

    /// "Reinstall helper" in setup: for a helper that's registered but not responding.
    func reinstallHelper() {
        guard !dryRun, AppLocation.isInApplications else { return }
        Task { @MainActor in
            await HelperRegistration.reregister()
            self.refreshSetup()
            self.pingHelper()
        }
    }

    private func pingHelper() {
        guard HelperRegistration.status == .enabled || dryRun else {
            helperReachable = false
            return
        }
        // Unknown counts as connected, so the helper never sleeps the Mac on a guess.
        let external = sensors.externalDisplayConnected() ?? true
        power.heartbeat(externalDisplayConnected: external) { [weak self] reachable, holdActive in
            guard let self else { return }
            self.helperReachable = reachable
            self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            if reachable { HelperRegistration.adoptFingerprintIfMissing() }
            if !self.dryRun, !self.triedReregister, AppLocation.isInApplications,
               HelperRegistration.helperChangedSinceRegistration || (!reachable && HelperRegistration.registeredFingerprint == nil) {
                // After an update that changed the helper, re-register right away,
                // while the user is at the Mac. launchd won't start a helper whose
                // cdhash changed (launch constraint), so waiting would leave it
                // broken after the next reboot. Once per launch.
                self.triedReregister = true
                Task { @MainActor in
                    await HelperRegistration.reregister()
                    self.refreshSetup()
                }
            }
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
        logSessionChanges(evaluated)

        // Heartbeat: every 30 s while a hold is active, every 60 s otherwise.
        if now - lastHeartbeat >= (engine.isActive ? 30 : 60) { pingHelper() }

        let power = sensors.power()
        let c = Conditions(
            holdWanted: SessionAggregator.holdWanted(live),
            helperReady: setup == .ready && helperReachable,
            appLocationOK: dryRun || AppLocation.isInApplications,
            thermal: sensors.thermal(),
            lidClosed: sensors.lidClosed(),
            externalDisplayConnected: sensors.externalDisplayConnected(),
            otherSleepAssertions: sensors.otherSleepAssertions(excluding: [getpid()], onAC: power == .ac),
            power: power,
            lowPowerMode: sensors.lowPowerMode()
        )
        // Record state changes that matter for safety, so real-hardware runs can be reviewed.
        if c.thermal != lastConditions.thermal {
            appLog.notice("Thermal state: \(String(describing: c.thermal), privacy: .public) (hold active: \(self.engine.isActive, privacy: .public))")
        }
        if c.lidClosed != lastConditions.lidClosed {
            appLog.notice("Lid closed: \(String(describing: c.lidClosed), privacy: .public)")
            if c.lidClosed == false { showWhileAwayAlertIfNeeded() }
        }
        // Re-check notification permission every 5 min (the user may change it in System Settings).
        if now - lastNotificationCheck >= 300 {
            lastNotificationCheck = now
            Notifier.isAllowed { [weak self] allowed in
                guard let self, self.notificationsAllowed != allowed else { return }
                self.notificationsAllowed = allowed
                appLog.notice("Notifications allowed: \(allowed, privacy: .public)")
            }
        }
        if c.power != lastConditions.power, case .battery = c.power, case .battery = lastConditions.power {
            // Battery percentage changes are too frequent to log.
        } else if c.power != lastConditions.power {
            appLog.notice("Power: \(String(describing: c.power), privacy: .public)")
        }
        if c.lowPowerMode != lastConditions.lowPowerMode {
            appLog.notice("Low Power Mode: \(c.lowPowerMode, privacy: .public)")
        }
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
    func pauseOneHour() { pause(for: 3600) }
    /// nil pauses until the user resumes.
    func pause(for duration: TimeInterval?) {
        command(.pause(until: duration.map { ProcessInfo.processInfo.systemUptime + $0 } ?? .infinity))
    }
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

    // MARK: - Uninstall

    struct UninstallResult {
        var removedIntegrations: [String]
        var failures: [String]
    }

    /// Restores everything Hibermate changed:
    /// 1. Release any hold, so the helper restores the original SleepDisabled.
    /// 2. Remove Hibermate's entries from every tool (each file is backed up first).
    /// 3. Unregister the helper; on SIGTERM it restores again and removes its state.
    /// 4. Delete ~/Library/Application Support/Hibermate.
    /// The caller then offers to move the app to the Trash and quits.
    func uninstall(completion: @escaping (UninstallResult) -> Void) {
        timer?.invalidate()
        let release = engine.handle(.quit, now: ProcessInfo.processInfo.systemUptime, conditions: lastConditions)
        run(release + [.endHold(.quitting)]) { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var removed: [String] = []
            if self.dryRun {
                appLog.notice("[dry-run] would remove all integrations, unregister the helper, and delete \(self.paths.supportDirectory.path, privacy: .public)")
                completion(UninstallResult(removedIntegrations: [], failures: []))
                return
            }
            let report = IntegrationLocations.removeAll()
            removed = report.removed
            failures += report.failed.map { "\($0.name): \($0.reason)" }
            Task { @MainActor in
                if HelperRegistration.status != .notRegistered {
                    do { try await HelperRegistration.unregister() } catch {
                        failures.append("Helper: \(error.localizedDescription)")
                    }
                }
                do { try FileManager.default.removeItem(at: self.paths.supportDirectory) } catch CocoaError.fileNoSuchFile {
                } catch {
                    failures.append("Could not delete \(self.paths.supportDirectory.path): \(error.localizedDescription)")
                }
                completion(UninstallResult(removedIntegrations: removed, failures: failures))
            }
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
                    } else {
                        // Give the helper a fresh external-display report right away.
                        self.pingHelper()
                    }
                    next()
                }
            case .endHold(let reason):
                appLog.notice("Hold ended: \(reason.rawValue, privacy: .public)")
                let sleeping = queue.contains { if case .sleepNow = $0 { true } else { false } }
                if !sleeping, ![.userReleased, .paused, .quitting, .helperUnavailable].contains(reason) {
                    logWhyNotSleeping()
                }
                power.endHold { _ in next() }
            case .sleepNow(let reason):
                appLog.notice("Sleeping the Mac: \(reason.rawValue, privacy: .public)")
                power.sleepNow()
                next()
            case .notifySafetyRelease(let reason, let slept):
                logSafetyRelease(reason, slept: slept)
                recordSafetyRelease(reason, slept: slept)
                next()
            }
        }
        next()
    }

    /// Logs each session's status when it changes, e.g. "holding" →
    /// "permission wait expired" or "dead: process exited". Session IDs and
    /// states only; never prompts or paths.
    private func logSessionChanges(_ sessions: [EvaluatedSession]) {
        var current: [String: String] = [:]
        for s in sessions {
            let status: String = switch s.verdict {
            case .holding: "holding (\(s.record.state.rawValue))"
            case .notHolding(let why): "not holding: \(why.rawValue)"
            case .dead(let why): "dead: \(why.rawValue)"
            }
            current[s.record.key] = status
            if lastSessionStatus[s.record.key] != status {
                appLog.notice("Session \(s.record.key, privacy: .public): \(status, privacy: .public)")
            }
        }
        for key in lastSessionStatus.keys where current[key] == nil {
            appLog.notice("Session \(key, privacy: .public): ended")
        }
        lastSessionStatus = current.filter { !$0.value.hasPrefix("dead") }
    }

    // MARK: - Integrations

    func refreshIntegrations() {
        enabledIntegrations = Set(integrations.filter { $0.isEnabled() }.map(\.id))
    }

    func setIntegration(_ integration: AgentIntegration, enabled: Bool) {
        do {
            if enabled { try integration.enable() } else { try integration.disable() }
            integrationError = nil
        } catch {
            integrationError = "\(integration.displayName): \(Self.describe(error))"
        }
        refreshIntegrations()
    }

    static func describe(_ error: Error) -> String {
        switch error as? ClaudeSettingsError {
        case .corrupt(let why): "the settings file isn't valid JSON (\(why)). Hibermate won't edit it; please fix it first."
        case .unexpectedShape(let why): "the settings file has an unexpected layout (\(why)). Hibermate won't edit it."
        case .claudeDirectoryMissing: "the tool's settings folder wasn't found."
        case .concurrentModification: "the settings file changed while Hibermate was editing it. Please try again."
        case .io(let why): why
        case nil: error.localizedDescription
        }
    }

    // MARK: - Safety release history

    /// Every safety release is kept in a short local history. If macOS allows
    /// notifications, one is posted. Otherwise (e.g. unsigned builds) the user is
    /// told with a "While you were away" alert the next time the lid opens, or
    /// right away if it's already open.
    private func recordSafetyRelease(_ reason: ReleaseReason, slept: Bool) {
        let notify = settings.notificationsEnabled && notificationsAllowed == true
        history.add(SafetyReleaseRecord(date: Date(), reason: reason, slept: slept, acknowledged: notify))
        if notify {
            Notifier.post(reason, slept: slept)
        } else if lastConditions.lidClosed == false, !slept {
            showWhileAwayAlertIfNeeded()
        }
    }

    private func showWhileAwayAlertIfNeeded() {
        let pending = history.unacknowledged
        guard !pending.isEmpty else { return }
        history.acknowledgeAll()
        let time = DateFormatter()
        time.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = pending.count == 1 ? "While you were away" : "While you were away (\(pending.count) safety releases)"
        alert.informativeText = pending.map { "\(time.string(from: $0.date)) — \($0.summary)" }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if notificationsAllowed == false {
            alert.informativeText += "\n\nTip: turn on Hibermate in System Settings → Notifications to be notified as it happens."
            alert.addButton(withTitle: "Open Notification Settings")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { Notifier.openSettings() }
    }

    /// Invariant 3 kept the Mac awake after a release: record which condition did.
    private func logWhyNotSleeping() {
        let c = lastConditions
        let blockers = c.otherSleepAssertions == true ? sensors.describeOtherSleepAssertions(excluding: [getpid()]) : []
        let summary = "lid closed: \(String(describing: c.lidClosed)), external display: "
            + "\(String(describing: c.externalDisplayConnected)), other sleep assertions: "
            + "\(String(describing: c.otherSleepAssertions)) \(blockers.joined(separator: "; "))"
        appLog.notice("Not sleeping the Mac (\(summary, privacy: .public))")
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
        s.lid = switch c.lidClosed {
        case true?: "Lid: closed"
        case false?: "Lid: open"
        case nil: "Lid: unknown (no lid sensor)"
        }
        s.display = switch c.externalDisplayConnected {
        case true?: "External display: connected (the Mac is never put to sleep)"
        case false?: "External display: none"
        case nil: "External display: unknown"
        }
        s.otherApps = switch c.otherSleepAssertions {
        case true?: "Another app is blocking lid-close sleep on power (Hibermate won't force sleep)"
        case false?: "Nothing is blocking lid-close sleep"
        case nil: "Couldn't check other apps' sleep assertions"
        }
        if let left = engine.timeRemaining(now: now, conditions: c, limits: limits) {
            s.timeRemaining = "Max hold ends in \(Self.format(left))"
        }

        let wall = Date().timeIntervalSince1970
        s.sessions = sessions.map { e in
            let r = e.record
            let agent = integrations.first { $0.id == r.agent }?.displayName
                ?? ActivityCatalog.tools.first { $0.id == r.agent }?.displayName
                ?? (r.agent == .generic ? "Script" : r.agent.rawValue)
            let status: MenuSnapshot.SessionRow.Status = switch (r.state, e.verdict) {
            case (_, .notHolding(.permissionWaitExpired)): .timedOut
            case (.working, _): .working
            case (.waiting, _): .waiting
            case (.background, _): .background
            case (.idle, _): .idle
            }
            return .init(id: r.key, agent: r.agent, agentName: agent, project: r.project ?? agent, status: status,
                         elapsed: Self.format(max(0, wall - r.stateSince)), holds: e.holds)
        }
        .sorted { ($0.holds ? 0 : 1, $0.project) < ($1.holds ? 0 : 1, $1.project) }
        s.thermalLevel = c.thermal
        s.batteryShort = switch c.power {
        case .ac: "Power"
        case .battery(let p): "\(p)%"
        case .unknown: "—"
        }
        if let left = engine.timeRemaining(now: now, conditions: c, limits: limits) {
            s.timeLeftShort = Self.format(left)
        }

        if sensors.batteryNeedsService() { s.warnings.append("Battery service recommended") }
        s.recentReleases = Array(history.records.prefix(5))
        s.notificationsAllowed = notificationsAllowed
        if let latched = engine.latchedReason {
            s.warnings.append("Paused for safety: \(latched.notificationBody(slept: false)) Open the lid to re-arm.")
        }

        switch setup {
        case .wrongLocation:
            s.icon = .setupNeeded; s.headline = "Move to Applications"
            s.subtitle = "Hibermate must run from Applications"
        case .helperNotRegistered:
            s.icon = .setupNeeded; s.headline = "Setup needed"
            s.subtitle = "Install the sleep helper to start"
        case .helperNeedsApproval:
            s.icon = .setupNeeded; s.headline = "Approval needed"
            s.subtitle = "Allow Hibermate in Login Items"
        case .helperUnreachable:
            s.icon = .warning; s.headline = "Helper not responding"
            s.subtitle = "Reinstall it from Hibermate's window"
        case .ready:
            let working = sessions.filter(\.holds).count
            switch engine.phase {
            case .holding:
                s.icon = .holding; s.headline = "Keeping your Mac awake"
                s.subtitle = (working == 1 ? "1 session working" : "\(working) sessions working")
                    + (s.timeLeftShort.map { " · \($0) left" } ?? "")
            case .grace(let until):
                s.icon = .grace; s.headline = "Work finished"
                s.subtitle = "Normal sleep returns in \(Self.format(max(0, until - now)))"
            case .idle:
                if c.holdWanted, let blocker = engine.startBlocker(c, limits: limits) {
                    // An agent is working but the Mac isn't being kept awake: say why.
                    s.icon = .warning
                    s.headline = "Not keeping the Mac awake"
                    s.subtitle = blocker.explanation.prefix(1).uppercased() + blocker.explanation.dropFirst()
                    s.warnings.append("Not keeping the Mac awake: \(blocker.explanation).")
                } else if engine.latchedReason != nil {
                    s.icon = .warning; s.headline = "Released for safety"
                    s.subtitle = "Open the lid to re-arm"
                } else if s.isPaused {
                    s.icon = .idle; s.headline = "Paused"
                    s.subtitle = "Your Mac sleeps normally"
                } else {
                    s.icon = .idle; s.headline = "Sleeping normally"
                    s.subtitle = "No AI tools are working"
                }
            }
        }
        s.explanation = switch (setup, engine.phase) {
        case (.wrongLocation, _): "Hibermate must run from the Applications folder before it can keep your Mac awake."
        case (.helperNotRegistered, _), (.helperNeedsApproval, _), (.helperUnreachable, _):
            "Until setup is finished, your Mac sleeps normally."
        case (.ready, .holding): "An AI tool is working. You can close the lid; the display turns off and the work continues."
        case (.ready, .grace): "All work finished. Waiting a little in case more arrives, then normal sleep returns."
        case (.ready, .idle) where lastConditions.holdWanted && engine.startBlocker(lastConditions, limits: limits) != nil:
            "If you close the lid, the Mac sleeps normally and the work pauses."
        case (.ready, .idle):
            engine.latchedReason != nil
                ? "Hibermate released the Mac to protect it. Open the lid to re-arm it."
                : "Your Mac sleeps normally. Hibermate starts holding as soon as an enabled AI tool starts working."
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
