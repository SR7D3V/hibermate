import Foundation
import HibermateCore
import IOKit
import IOKit.pwr_mgt
import os

let helperLog = Logger(subsystem: HelperIdentity.helperBundleID, category: "helper")

/// The real `SleepDisabled` control. It reads from the IORegistry
/// (IOPMrootDomain), and writes by running `/usr/bin/pmset` with a fixed
/// argument list: no shell and no caller-supplied strings. macOS has no public
/// API for writing this setting.
final class SystemSleepControl: SleepDisabledControl {
    func read() throws -> Bool {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
        guard root != MACH_PORT_NULL else { throw HelperError.settingFailed }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            // The key is absent when the setting has never been changed: not disabled.
            return false
        }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        throw HelperError.settingFailed
    }

    func write(_ disabled: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // The IORegistry can lag slightly behind pmset (seen on real hardware:
        // an immediate read still showed the old value). Wait up to 1 s.
        var applied = false
        for _ in 0..<20 where process.terminationStatus == 0 {
            if try read() == disabled { applied = true; break }
            usleep(50_000)
        }
        guard process.terminationStatus == 0, applied else {
            helperLog.error("pmset disablesleep \(disabled ? 1 : 0, privacy: .public) failed (status \(process.terminationStatus, privacy: .public))")
            throw HelperError.settingFailed
        }
        helperLog.notice("SleepDisabled set to \(disabled ? 1 : 0, privacy: .public)")
    }
}

/// Root-owned state file that exists only while a hold is active:
/// `/Library/Application Support/Hibermate/helper-state.json`.
final class FileHelperStateStore: HelperStateStore {
    let directory = URL(fileURLWithPath: "/Library/Application Support/Hibermate", isDirectory: true)
    var file: URL { directory.appendingPathComponent("helper-state.json") }

    func load() -> HelperHoldState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        // A file that exists but is unreadable still means "a hold may be active".
        // Assume the safe original (sleep enabled), so restoring can't leave sleep disabled.
        return (try? JSONDecoder().decode(HelperHoldState.self, from: data))
            ?? HelperHoldState(originalSleepDisabled: false, startedAt: 0)
    }

    func save(_ state: HelperHoldState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try AtomicFile.write(try JSONEncoder().encode(state), to: file, permissions: 0o600)
    }

    func clear() throws {
        if unlink(file.path) != 0, errno != ENOENT { throw HelperError.stateNotPersisted }
        // Leave nothing behind: remove the directory once it's empty.
        rmdir(directory.path)
    }
}

enum SystemSleep {
    /// `AppleClamshellState` from IOPMrootDomain; nil if unreadable or there's no lid.
    static func lidClosed() -> Bool? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
        guard root != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    /// Requires root. The app decides whether sleeping is safe; the helper only
    /// rate-limits, so a misbehaving caller can't put the Mac into a sleep loop.
    private static var lastSleep: TimeInterval = -.infinity

    static func sleepNow() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSleep >= 60 else { return false }
        lastSleep = now
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != MACH_PORT_NULL else { return false }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        helperLog.notice("Sleep requested (result \(result, privacy: .public))")
        return result == kIOReturnSuccess
    }
}
