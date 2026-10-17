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
    private var lastHeartbeat: TimeInterval?

    /// - Parameters:
    ///   - clock: monotonic seconds, for the dead-man deadline.
    ///   - wallClock: seconds since 1970, recorded in the state file for diagnostics.
    public init(control: SleepDisabledControl, store: HelperStateStore,
                clock: @escaping () -> TimeInterval, wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.control = control
        self.store = store
        self.clock = clock
        self.wallClock = wallClock
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

    public func heartbeat() {
        guard store.load() != nil else { return }
        lastHeartbeat = clock()
    }

    /// Call periodically (e.g. every 10 s). Restores if the app has gone quiet.
    public func tick() {
        guard store.load() != nil else { return }
        let last = lastHeartbeat ?? -.infinity
        if clock() - last >= Self.heartbeatDeadline { restore() }
    }

    /// The app's XPC connection dropped (crash, force quit). Restore right away
    /// rather than waiting for the dead-man deadline.
    public func connectionInvalidated() {
        restore()
    }

    /// SIGTERM from launchd (unregistration, uninstall, shutdown).
    public func terminate() {
        restore()
    }

    /// Idempotent. With no recorded hold it does nothing, so a SleepDisabled
    /// the user set themselves is never touched. If the write fails, the state
    /// file is kept so `tick()` and the next start retry.
    public func restore() {
        guard let state = store.load() else {
            lastHeartbeat = nil
            return
        }
        do {
            if try control.read() != state.originalSleepDisabled {
                try control.write(state.originalSleepDisabled)
            }
            try store.clear()
            lastHeartbeat = nil
        } catch {
            // Keep the state so a later tick or start retries. Force the
            // dead-man deadline to have passed so the next tick tries again.
            lastHeartbeat = -.infinity
        }
    }
}
