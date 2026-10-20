import Foundation

/// Snapshot of everything the engine needs to decide. Optional sensor values
/// mean "could not be read". Each one is interpreted in the safe direction: an
/// unknown lid counts as closed for the thermal timer, but never as closed when
/// deciding whether to call sleep.
public struct Conditions: Equatable, Sendable {
    /// At least one session (hook or watched process) wants the Mac awake.
    public var holdWanted: Bool
    /// The helper is approved in Login Items and answered a ping.
    public var helperReady: Bool
    /// The app runs from /Applications and is not translocated.
    public var appLocationOK: Bool
    public var thermal: ThermalLevel
    public var lidClosed: Bool?
    public var externalDisplayConnected: Bool?
    /// Another process holds a system-sleep-prevention assertion (ours excluded).
    public var otherSleepAssertions: Bool?
    public var power: PowerSource
    public var lowPowerMode: Bool

    public init(holdWanted: Bool = false, helperReady: Bool = true, appLocationOK: Bool = true,
                thermal: ThermalLevel = .nominal, lidClosed: Bool? = false,
                externalDisplayConnected: Bool? = false, otherSleepAssertions: Bool? = false,
                power: PowerSource = .ac, lowPowerMode: Bool = false) {
        self.holdWanted = holdWanted
        self.helperReady = helperReady
        self.appLocationOK = appLocationOK
        self.thermal = thermal
        self.lidClosed = lidClosed
        self.externalDisplayConnected = externalDisplayConnected
        self.otherSleepAssertions = otherSleepAssertions
        self.power = power
        self.lowPowerMode = lowPowerMode
    }
}

/// Side effects the engine asks for. The executor runs them in order. Each one
/// is idempotent: `beginHold` while already holding, or `endHold` while not
/// holding, is a no-op on the system.
public enum Effect: Equatable, Sendable {
    /// Helper: disable sleep. App: create the PreventUserIdleSystemSleep
    /// assertion and start the heartbeat.
    case beginHold
    /// Helper: restore the original SleepDisabled. App: release the assertion and stop the heartbeat.
    case endHold(ReleaseReason)
    /// Helper: sleep now. Only emitted after every applicable "never sleep a Mac
    /// someone is using" check has passed.
    case sleepNow(ReleaseReason)
    case notifySafetyRelease(ReleaseReason, slept: Bool)
}

public enum Phase: Equatable, Sendable {
    case idle
    case holding
    case grace(until: TimeInterval)
}

public enum StartBlocker: Equatable, Sendable {
    case setupIncomplete
    case latched(ReleaseReason)
    case paused
    case releasedByUser
    case tooHot(ThermalLevel)
    case batteryLow(percent: Int, threshold: Int)
    case powerUnknown

    /// Plain words for the menu and window.
    public var explanation: String {
        switch self {
        case .setupIncomplete: "setup isn't finished"
        case .latched: "it was released for safety; open the lid to re-arm"
        case .paused: "Hibermate is paused"
        case .releasedByUser: "you chose Release now; it re-arms when the current work finishes"
        case .tooHot(let t): "the Mac is \(t.plainDescription.lowercased())"
        case .batteryLow(let p, let t): "the battery is at \(p)% (limit \(t)%); plug in to continue"
        case .powerUnknown: "the battery level can't be read"
        }
    }
}

public enum UserCommand: Equatable, Sendable {
    case releaseNow
    case pause(until: TimeInterval)
    case resume
    case quit
    /// The executor could not reach the helper while acting on an effect.
    case helperFailed
}

/// The hold state machine: Idle → Holding → Grace → Idle, with forced
/// (safety) releases from any active state.
///
/// Pure and deterministic. Callers pass a monotonic `now` (seconds) with fresh
/// `Conditions` on every sensor or session change, and at least every few
/// seconds as a tick. Every call is safe to repeat.
public struct HoldEngine: Sendable {
    public private(set) var phase: Phase = .idle
    /// Start of the current hold. Preserved across grace → holding, so max hold
    /// counts time spent in grace.
    public private(set) var holdStartedAt: TimeInterval?
    /// Set by a safety release. No new hold until the re-arm conditions are met.
    public private(set) var latchedReason: ReleaseReason?
    public private(set) var pausedUntil: TimeInterval?
    public private(set) var lastRelease: ReleaseReason?

    private var lidOpenedSinceLatch = false
    private var fairSince: TimeInterval?
    /// After "Release now", don't re-hold until the current work has gone idle once.
    private var suppressedUntilIdle = false

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// Seconds left before the max-hold (or Low Power Mode) cutoff, for the menu.
    public func timeRemaining(now: TimeInterval, conditions c: Conditions, limits: EffectiveLimits) -> TimeInterval? {
        guard let start = holdStartedAt else { return nil }
        let cap = c.lowPowerMode ? limits.lowPowerHoldCap : limits.maxHold
        return max(0, cap - (now - start))
    }

    public mutating func update(now: TimeInterval, conditions c: Conditions, limits: EffectiveLimits) -> [Effect] {
        if !c.holdWanted { suppressedUntilIdle = false }
        if let until = pausedUntil, now >= until { pausedUntil = nil }
        updateLatch(c, limits: limits)

        switch phase {
        case .idle:
            fairSince = nil
            guard canStartHold(c, limits: limits) else { return [] }
            phase = .holding
            holdStartedAt = now
            return [.beginHold]

        case .holding, .grace:
            if !c.helperReady || !c.appLocationOK {
                return release(.helperUnavailable, conditions: c)
            }
            if let reason = safetyViolation(now: now, conditions: c, limits: limits) {
                return release(reason, conditions: c)
            }
            if phase == .holding, !c.holdWanted {
                phase = .grace(until: now + limits.gracePeriod)
                return []
            }
            if case .grace(let until) = phase {
                // Thermal and battery were checked just above, so resuming here is safe.
                if c.holdWanted, !suppressedUntilIdle {
                    phase = .holding
                    return []
                }
                if now >= until {
                    return release(.graceExpired, conditions: c)
                }
            }
            return []
        }
    }

    public mutating func handle(_ command: UserCommand, now: TimeInterval, conditions c: Conditions) -> [Effect] {
        switch command {
        case .releaseNow:
            suppressedUntilIdle = c.holdWanted
            return isActive ? release(.userReleased, conditions: c) : []
        case .pause(let until):
            pausedUntil = until
            return isActive ? release(.paused, conditions: c) : []
        case .resume:
            pausedUntil = nil
            return []
        case .quit:
            return isActive ? release(.quitting, conditions: c) : []
        case .helperFailed:
            return isActive ? release(.helperUnavailable, conditions: c) : []
        }
    }

    // MARK: - Rules

    private func canStartHold(_ c: Conditions, limits: EffectiveLimits) -> Bool {
        c.holdWanted && startBlocker(c, limits: limits) == nil
    }

    /// Why a hold can't start right now, regardless of whether one is wanted.
    /// The UI shows this when an agent is working but the Mac isn't being kept
    /// awake, so "No agents working" is never shown when that isn't true.
    public func startBlocker(_ c: Conditions, limits: EffectiveLimits) -> StartBlocker? {
        if !c.appLocationOK { return .setupIncomplete }
        if !c.helperReady { return .setupIncomplete }
        if let latched = latchedReason { return .latched(latched) }
        if pausedUntil != nil { return .paused }
        if suppressedUntilIdle { return .releasedByUser }
        // Never start (or resume) under serious or critical thermal pressure.
        if c.thermal > .fair { return .tooHot(c.thermal) }
        switch c.power {
        case .ac: return nil
        case .battery(let percent):
            return percent > limits.batteryThreshold ? nil : .batteryLow(percent: percent, threshold: limits.batteryThreshold)
        case .unknown: return .powerUnknown
        }
    }

    /// Hardware-safety checks while a hold is active, most severe first.
    private mutating func safetyViolation(now: TimeInterval, conditions c: Conditions, limits: EffectiveLimits) -> ReleaseReason? {
        if c.thermal == .critical { return .thermalCritical }
        if c.thermal == .serious { return .thermalSerious }

        switch c.power {
        case .ac: break
        case .battery(let percent) where percent <= limits.batteryThreshold: return .batteryLow
        case .battery: break
        case .unknown: return .powerUnknown
        }

        // An unknown lid state counts as closed here (stricter).
        if c.thermal == .fair, c.lidClosed != false {
            let since = fairSince ?? now
            fairSince = since
            if now - since >= limits.fairTimeout { return .thermalSustainedFair }
        } else {
            fairSince = nil
        }

        let held = now - (holdStartedAt ?? now)
        if c.lowPowerMode, held >= limits.lowPowerHoldCap { return .lowPowerModeLimit }
        if held >= min(limits.maxHold, SafetyLimits.maxHoldHardCeiling) { return .maxHoldReached }
        return nil
    }

    private mutating func updateLatch(_ c: Conditions, limits: EffectiveLimits) {
        guard latchedReason != nil else { return }
        if c.lidClosed == false { lidOpenedSinceLatch = true }
        let batteryRecovered: Bool = switch c.power {
        case .ac: true
        case .battery(let percent): percent >= limits.batteryThreshold + SafetyLimits.rearmBatteryMargin
        case .unknown: false
        }
        if lidOpenedSinceLatch, c.thermal <= .fair, batteryRecovered {
            latchedReason = nil
            lidOpenedSinceLatch = false
        }
    }

    private mutating func release(_ reason: ReleaseReason, conditions c: Conditions) -> [Effect] {
        phase = .idle
        holdStartedAt = nil
        fairSince = nil
        lastRelease = reason
        var effects: [Effect] = [.endHold(reason)]
        let slept = Self.shouldSleep(after: reason, conditions: c)
        if slept { effects.append(.sleepNow(reason)) }
        if reason.isSafetyRelease {
            latchedReason = reason
            lidOpenedSinceLatch = false
            effects.append(.notifySafetyRelease(reason, slept: slept))
        }
        return effects
    }

    /// Invariant 3: never sleep a Mac someone is using. The lid must be known
    /// closed and no external display connected. Other processes' sleep
    /// assertions are respected unless thermal pressure is critical. Unknown
    /// values count as "someone may be using it".
    public static func shouldSleep(after reason: ReleaseReason, conditions c: Conditions) -> Bool {
        guard !reason.forbidsSleep else { return false }
        guard c.lidClosed == true, c.externalDisplayConnected == false else { return false }
        if reason == .thermalCritical { return true }
        return c.otherSleepAssertions == false
    }
}
