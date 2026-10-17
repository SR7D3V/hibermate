import Foundation

/// Mirror of `ProcessInfo.ThermalState`, kept separate so the core logic can be
/// tested without the real sensor. macOS calibrates thermal pressure per model,
/// which makes it the primary hardware-safety signal.
public enum ThermalLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Plain words for the menu.
    public var plainDescription: String {
        switch self {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        }
    }
}

public enum PowerSource: Equatable, Sendable {
    case ac
    case battery(percent: Int)
    /// The power source could not be read. Treated as "do not hold" (fail safe).
    case unknown
}

/// Why a hold ended. Safety releases latch Hibermate off until the re-arm
/// conditions are met (see `HoldEngine`).
public enum ReleaseReason: String, Sendable, Equatable, Codable {
    // Hardware safety releases.
    case thermalCritical
    case thermalSerious
    case thermalSustainedFair
    case batteryLow
    case powerUnknown
    case lowPowerModeLimit
    case maxHoldReached
    // Normal or user-initiated releases.
    case graceExpired
    case userReleased
    case paused
    case quitting
    case helperUnavailable

    public var isSafetyRelease: Bool {
        switch self {
        case .thermalCritical, .thermalSerious, .thermalSustainedFair,
             .batteryLow, .powerUnknown, .lowPowerModeLimit, .maxHoldReached:
            true
        case .graceExpired, .userReleased, .paused, .quitting, .helperUnavailable:
            false
        }
    }

    /// The user is at the machine (or the helper is gone): never call sleep.
    var forbidsSleep: Bool {
        switch self {
        case .userReleased, .paused, .quitting, .helperUnavailable: true
        default: false
        }
    }

    /// Text for the local notification posted on a safety release.
    public func notificationBody(slept: Bool) -> String {
        let outcome = slept ? "Hibermate put your Mac to sleep" : "Hibermate stopped keeping your Mac awake"
        let why: String = switch self {
        case .thermalCritical, .thermalSerious: "it was getting too hot with the lid closed."
        case .thermalSustainedFair: "it stayed warm with the lid closed for too long."
        case .batteryLow: "the battery is low."
        case .powerUnknown: "the battery level could not be read."
        case .lowPowerModeLimit: "Low Power Mode is on, which limits how long it stays awake."
        case .maxHoldReached: "it reached the maximum hold time."
        default: "the session ended."
        }
        return "\(outcome): \(why)"
    }
}
