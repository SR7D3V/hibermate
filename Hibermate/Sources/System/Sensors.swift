import CoreGraphics
import Foundation
import HibermateCore
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Read-only sensors. Every reading that can fail returns nil, and the engine
/// treats nil in the safe direction.
protocol SystemSensing {
    func thermal() -> ThermalLevel
    func power() -> PowerSource
    func lowPowerMode() -> Bool
    func lidClosed() -> Bool?
    func externalDisplayConnected() -> Bool?
    func otherSleepAssertions(excluding pids: Set<pid_t>) -> Bool?
    /// "process: type "name"" for each blocking assertion, for logs.
    func describeOtherSleepAssertions(excluding pids: Set<pid_t>) -> [String]
    func batteryNeedsService() -> Bool
    func modelIdentifier() -> String?
}

struct LiveSensors: SystemSensing {
    func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical // unknown future state: assume the worst
        }
    }

    func lowPowerMode() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func power() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .unknown }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var internalBattery: [String: Any]?
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { internalBattery = d }
        }
        // No internal battery (desktop Mac): treat as AC.
        guard let battery = internalBattery else { return list.isEmpty ? .ac : .unknown }
        if providing == kIOPMACPowerKey { return .ac }
        guard providing == kIOPMBatteryPowerKey,
              let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let max = battery[kIOPSMaxCapacityKey] as? Int, max > 0 else { return .unknown }
        return .battery(percent: Int((Double(current) / Double(max) * 100).rounded(.down)))
    }

    func batteryNeedsService() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let condition = d[kIOPSBatteryHealthConditionKey] as? String, !condition.isEmpty { return true }
            if d[kIOPSBatteryHealthKey] as? String == kIOPSPoorValue { return true }
        }
        return false
    }

    /// `AppleClamshellState` read directly from IOPMrootDomain (not by parsing `ioreg`).
    func lidClosed() -> Bool? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
        guard root != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            return nil // no lid (desktop Mac) or unreadable
        }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    func externalDisplayConnected() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Any other process holding an assertion that prevents system sleep. Examples:
    /// a download, a Time Machine backup, or the user's own `caffeinate`.
    func otherSleepAssertions(excluding pids: Set<pid_t>) -> Bool? {
        blockingAssertions(excluding: pids).map { !$0.isEmpty }
    }

    func describeOtherSleepAssertions(excluding pids: Set<pid_t>) -> [String] {
        blockingAssertions(excluding: pids) ?? ["(assertions unreadable)"]
    }

    private func blockingAssertions(excluding pids: Set<pid_t>) -> [String]? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        var found: [String] = []
        let preventing: Set<String> = [kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionTypePreventUserIdleSystemSleep,
                                       kIOPMAssertionTypeNoIdleSleep]
        for (pid, assertions) in dict where !pids.contains(pid.int32Value) {
            for a in assertions {
                guard let type = a[kIOPMAssertionTypeKey] as? String, preventing.contains(type) else { continue }
                // macOS's power manager holds this whenever the display is on, and
                // drops it when the lid closes. It isn't another app keeping the Mac
                // awake (seen on real hardware, 2026-10-17).
                if let name = a[kIOPMAssertionNameKey] as? String, name.hasPrefix("Powerd - Prevent sleep while display is on") {
                    continue
                }
                // Level 255 (kIOPMAssertionLevelOn) means the assertion is active.
                if (a[kIOPMAssertionLevelKey] as? Int ?? 255) == Int(kIOPMAssertionLevelOn) {
                    let owner = DarwinProcessTable().entry(for: pid.int32Value)?.name ?? "pid \(pid)"
                    found.append("\(owner): \(type) \"\(a[kIOPMAssertionNameKey] as? String ?? "")\"")
                }
            }
        }
        return found
    }

    func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
