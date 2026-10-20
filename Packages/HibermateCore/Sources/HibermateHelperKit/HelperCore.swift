import Foundation

/// Reads and writes the system `SleepDisabled` power setting. The real
/// implementation runs only inside the root helper. Tests use a fake.
public protocol SleepDisabledControl: AnyObject {
    func read() throws -> Bool
    func write(_ disabled: Bool) throws
}

/// Persists the value Hibermate must restore. This survives a helper crash or
/// reboot during a hold. The real store is a root-owned file that exists only
/// while a hold is active.
public protocol HelperStateStore: AnyObject {
    func load() -> HelperHoldState?
    func save(_ state: HelperHoldState) throws
    func clear() throws
}

public struct HelperHoldState: Codable, Equatable, Sendable {
    /// The user's `SleepDisabled` value before the hold. Restored exactly:
    /// if it was already true, it stays true.
    public var originalSleepDisabled: Bool
    public var startedAt: Double

    public init(originalSleepDisabled: Bool, startedAt: Double) {
        self.originalSleepDisabled = originalSleepDisabled
        self.startedAt = startedAt
    }
}

public enum HelperError: Error, Equatable {
    case stateNotPersisted
    case settingFailed
}

/// The privileged helper's logic, free of XPC and launchd so it can be tested.
///
/// Enforces invariant 1 (never stuck on) through the dead-man switch, connection
/// invalidation, termination, and start-up reconciliation. Enforces invariant 2
/// (never clobber) by restoring the saved original instead of writing `false`.
public final class HelperCore {
    public static let heartbeatDeadline: TimeInterval = 120

    private let control: SleepDisabledControl
    private let store: HelperStateStore
    private let clock: () -> TimeInterval
    private let wallClock: () -> Double
    private let appLoss: AppLossSleep?
    private var lastHeartbeat: TimeInterval?
    private var lastDisplayReport: (external: Bool, at: TimeInterval)?

    /// A display report older than this is too stale to trust for sleeping.
    public static let displayReportMaxAge: TimeInterval = 180

    /// What the helper does when the app is lost mid-hold (crash, or the dead-man
    /// deadline passes) with the lid closed (user decision, 2026-10-18).
    /// Restoring SleepDisabled alone leaves a lid-closed Mac awake, because macOS
    /// doesn't re-check lid sleep by itself. So the helper also sleeps it, under
    /// the same "never sleep a Mac someone is using" rules.
    public struct AppLossSleep {
        public var lidClosed: () -> Bool?
        public var sleep: () -> Void
        public init(lidClosed: @escaping () -> Bool?, sleep: @escaping () -> Void) {
            self.lidClosed = lidClosed
            self.sleep = sleep
        }
    }

    /// - Parameters:
    ///   - clock: monotonic seconds, for the dead-man deadline.
    ///   - wallClock: seconds since 1970, recorded in the state file for diagnostics.
    ///   - appLoss: how to read the lid and sleep the Mac; nil disables sleeping on app loss.
    public init(control: SleepDisabledControl, store: HelperStateStore,
                clock: @escaping () -> TimeInterval, wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                appLoss: AppLossSleep? = nil) {
        self.control = control
        self.store = store
        self.clock = clock
        self.wallClock = wallClock
        self.appLoss = appLoss
    }

    public var holdActive: Bool { store.load() != nil }

    /// Call on helper launch. A leftover state file means a hold was cut short
    /// (helper crash, reboot, or kill). Restore normal behavior. If the app is
    /// still working, it asks again.
    public func reconcileOnStart() {
        if store.load() != nil { restore() }
    }

    /// `true` starts or refreshes a hold. `false` restores the original value.
    public func setSleepDisabled(_ disabled: Bool) throws {
        if !disabled {
            restore()
            return
        }
        if store.load() == nil {
            let original = try control.read()
            // Save the original BEFORE changing anything, so a crash between
            // the two steps can always be undone.
            do {
                try store.save(HelperHoldState(originalSleepDisabled: original, startedAt: wallClock()))
            } catch {
                throw HelperError.stateNotPersisted
            }
        }
        lastHeartbeat = clock()
        if try control.read() == false {
            do {
                try control.write(true)
            } catch {
                restore()
                throw HelperError.settingFailed
            }
        }
    }

    /// - Parameter externalDisplayConnected: the app's latest reading. The helper
    ///   can't reliably query displays itself as a daemon. nil means unknown.
    public func heartbeat(externalDisplayConnected: Bool? = nil) {
        if let external = externalDisplayConnected { lastDisplayReport = (external, clock()) }
        guard store.load() != nil else { return }
        lastHeartbeat = clock()
    }

    /// Call periodically (e.g. every 10 s). Restores if the app has gone quiet.
    public func tick() {
        guard store.load() != nil else { return }
        let last = lastHeartbeat ?? -.infinity
        if clock() - last >= Self.heartbeatDeadline { restoreAfterAppLoss() }
    }

    /// The app's XPC connection dropped (crash, force quit). Restore right away
    /// rather than waiting for the dead-man deadline. After a normal quit no hold
    /// is recorded, so this does nothing.
    public func connectionInvalidated() {
        restoreAfterAppLoss()
    }

    /// SIGTERM from launchd (unregistration, uninstall, shutdown): restore only.
    /// Never sleep here, because someone is uninstalling or the Mac is shutting down.
    public func terminate() {
        restore()
    }

    /// Restore, then sleep the Mac if nobody is using it. That means the lid
    /// is known closed, and a recent report says no external display.
    /// Anything unknown means no sleep (fail safe).
    private func restoreAfterAppLoss() {
        guard store.load() != nil, restore() else { return }
        guard let appLoss, appLoss.lidClosed() == true,
              let report = lastDisplayReport, report.external == false,
              clock() - report.at <= Self.displayReportMaxAge else { return }
        appLoss.sleep()
    }

    /// Idempotent. With no recorded hold it does nothing, so a SleepDisabled
    /// the user set themselves is never touched. If the write fails, the state
    /// file is kept so `tick()` and the next start retry.
    @discardableResult
    public func restore() -> Bool {
        guard let state = store.load() else {
            lastHeartbeat = nil
            return true
        }
        do {
            if try control.read() != state.originalSleepDisabled {
                try control.write(state.originalSleepDisabled)
            }
            try store.clear()
            lastHeartbeat = nil
            return true
        } catch {
            // Keep the state so a later tick or start retries. Force the
            // dead-man deadline to have passed so the next tick tries again.
            lastHeartbeat = -.infinity
            return false
        }
    }
}
