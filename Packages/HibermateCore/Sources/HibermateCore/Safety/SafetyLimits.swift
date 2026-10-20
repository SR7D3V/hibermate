import Foundation

/// Every safety-relevant bound lives here. These numbers are Hibermate design
/// choices, not Apple specifications. Apple publishes only ambient operating
/// ranges (10–35 °C), and no internal temperature limits.
public enum SafetyLimits {
    // Max hold: user-adjustable, with a hard ceiling that no setting, corrupted
    // file, or code path can exceed. Raising the ceiling needs a new release.
    public static let maxHoldDefault: TimeInterval = 4 * 3600
    public static let maxHoldMinimum: TimeInterval = 15 * 60
    public static let maxHoldHardCeiling: TimeInterval = 12 * 3600

    // Battery: users may raise the threshold, never lower it below 20%.
    public static let batteryThresholdDefault = 20
    public static let batteryThresholdRange = 20...80
    /// After a battery release, a hold may re-arm only above threshold + margin (or on AC).
    public static let rearmBatteryMargin = 5

    // Low Power Mode caps any hold at min(this, max hold).
    public static let lowPowerModeCap: TimeInterval = 30 * 60

    // Sustained `.fair` with the lid closed.
    public static let fairTimeoutWithFans: TimeInterval = 10 * 60
    public static let fairTimeoutFanless: TimeInterval = 5 * 60
    public static let fairTimeoutMinimum: TimeInterval = 60

    // Grace period. The 30 s floor lets a Stop → UserPromptSubmit handoff between
    // queued prompts happen without releasing; the 5 min cap keeps it short.
    public static let graceDefault: TimeInterval = 60
    public static let graceRange: ClosedRange<TimeInterval> = 30...300

    // Session liveness (tighten only).
    public static let permissionWaitDefault: TimeInterval = 5 * 60
    public static let permissionWaitRange: ClosedRange<TimeInterval> = 60...(5 * 60)
    public static let staleWindowDefault: TimeInterval = 15 * 60
    public static let staleWindowRange: ClosedRange<TimeInterval> = (5 * 60)...(15 * 60)
    /// Used instead of the stale window while a tool call is in flight, so a long
    /// build or test run isn't mistaken for a lost Stop event. Always bounded by max hold.
    public static let longToolWindow: TimeInterval = 60 * 60

    public static func fairTimeoutDefault(fanless: Bool) -> TimeInterval {
        fanless ? fairTimeoutFanless : fairTimeoutWithFans
    }
}

/// User-editable settings as stored on disk. Never used directly for decisions:
/// always go through `effectiveLimits(fanless:)`, which clamps everything.
public struct UserSettings: Codable, Equatable, Sendable {
    public var gracePeriod: TimeInterval = SafetyLimits.graceDefault
    public var maxHold: TimeInterval = SafetyLimits.maxHoldDefault
    public var batteryThreshold: Int = SafetyLimits.batteryThresholdDefault
    /// nil means "the default for this Mac" (10 min with fans, 5 min fanless).
    public var fairTimeout: TimeInterval? = nil
    public var permissionWait: TimeInterval = SafetyLimits.permissionWaitDefault
    public var staleWindow: TimeInterval = SafetyLimits.staleWindowDefault
    /// Activity-watching rule IDs (see `ActivityCatalog`) the user turned on.
    /// Empty means process watching is off, which is the default.
    public var watchedTools: [String] = []
    public var notificationsEnabled = true
    /// The once-a-day check for a newer release (see `UpdatePolicy`).
    public var checkForUpdates = true

    public init() {}

    // Missing or mistyped keys fall back to defaults, so an old or hand-edited
    // file never fails to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserSettings()
        gracePeriod = (try? c.decodeIfPresent(TimeInterval.self, forKey: .gracePeriod)) ?? d.gracePeriod
        maxHold = (try? c.decodeIfPresent(TimeInterval.self, forKey: .maxHold)) ?? d.maxHold
        batteryThreshold = (try? c.decodeIfPresent(Int.self, forKey: .batteryThreshold)) ?? d.batteryThreshold
        fairTimeout = (try? c.decodeIfPresent(TimeInterval.self, forKey: .fairTimeout)) ?? nil
        permissionWait = (try? c.decodeIfPresent(TimeInterval.self, forKey: .permissionWait)) ?? d.permissionWait
        staleWindow = (try? c.decodeIfPresent(TimeInterval.self, forKey: .staleWindow)) ?? d.staleWindow
        watchedTools = (try? c.decodeIfPresent([String].self, forKey: .watchedTools)) ?? d.watchedTools
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        checkForUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .checkForUpdates)) ?? d.checkForUpdates
    }

    public func effectiveLimits(fanless: Bool) -> EffectiveLimits {
        let fairDefault = SafetyLimits.fairTimeoutDefault(fanless: fanless)
        return EffectiveLimits(
            gracePeriod: clamp(gracePeriod, SafetyLimits.graceRange, fallback: SafetyLimits.graceDefault),
            maxHold: clamp(maxHold, SafetyLimits.maxHoldMinimum...SafetyLimits.maxHoldHardCeiling,
                           fallback: SafetyLimits.maxHoldDefault),
            batteryThreshold: min(max(batteryThreshold, SafetyLimits.batteryThresholdRange.lowerBound),
                                  SafetyLimits.batteryThresholdRange.upperBound),
            fairTimeout: clamp(fairTimeout ?? fairDefault, SafetyLimits.fairTimeoutMinimum...fairDefault,
                               fallback: fairDefault),
            permissionWait: clamp(permissionWait, SafetyLimits.permissionWaitRange,
                                  fallback: SafetyLimits.permissionWaitDefault),
            staleWindow: clamp(staleWindow, SafetyLimits.staleWindowRange,
                               fallback: SafetyLimits.staleWindowDefault)
        )
    }
}

/// Clamped limits that the engine actually uses.
public struct EffectiveLimits: Equatable, Sendable {
    public var gracePeriod: TimeInterval
    public var maxHold: TimeInterval
    public var batteryThreshold: Int
    public var fairTimeout: TimeInterval
    public var permissionWait: TimeInterval
    public var staleWindow: TimeInterval

    public var lowPowerHoldCap: TimeInterval { min(SafetyLimits.lowPowerModeCap, maxHold) }

    public static func defaults(fanless: Bool) -> EffectiveLimits {
        UserSettings().effectiveLimits(fanless: fanless)
    }
}

/// NaN and infinity fall back to the default; finite values are clamped into range.
private func clamp(_ value: TimeInterval, _ range: ClosedRange<TimeInterval>, fallback: TimeInterval) -> TimeInterval {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}
