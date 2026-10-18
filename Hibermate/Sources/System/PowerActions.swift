import CryptoKit
import Foundation
import HibermateCore
import IOKit.pwr_mgt
import os
import ServiceManagement

let appLog = Logger(subsystem: HelperIdentity.appBundleID, category: "app")

/// Everything that changes power behavior. The real implementation goes through
/// the helper; `DryRunPowerActions` only logs.
protocol PowerActions: AnyObject {
    func beginHold(completion: @escaping (Bool) -> Void)
    func endHold(completion: @escaping (Bool) -> Void)
    func sleepNow()
    /// Replies whether the helper is reachable, and whether it has a hold recorded.
    /// Passes the external-display state for the helper's app-loss sleep check.
    func heartbeat(externalDisplayConnected: Bool, completion: @escaping (_ reachable: Bool, _ holdActive: Bool) -> Void)
}

/// `PreventUserIdleSystemSleep` while holding, so idle sleep is blocked even
/// with the lid open. Display sleep is never prevented.
final class IdleSleepAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var isHeld = false

    func acquire() {
        guard !isHeld else { return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Hibermate: an AI agent is working" as CFString, &id)
        isHeld = result == kIOReturnSuccess
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        isHeld = false
    }
}

final class HelperPowerActions: PowerActions {
    private let assertion = IdleSleepAssertion()
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping () -> Void) -> HibermateHelperXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperIdentity.machServiceName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HibermateHelperXPC.self)
            c.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            appLog.error("Helper XPC error: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async(execute: onError)
        } as? HibermateHelperXPC
    }

    func beginHold(completion: @escaping (Bool) -> Void) {
        assertion.acquire()
        guard let helper = proxy(onError: { completion(false) }) else { completion(false); return }
        helper.setSleepDisabled(true) { ok in DispatchQueue.main.async { completion(ok) } }
    }

    func endHold(completion: @escaping (Bool) -> Void) {
        assertion.release()
        guard let helper = proxy(onError: { completion(false) }) else { completion(false); return }
        helper.setSleepDisabled(false) { ok in DispatchQueue.main.async { completion(ok) } }
    }

    func sleepNow() {
        proxy(onError: {})?.sleepNow { _ in }
    }

    func heartbeat(externalDisplayConnected: Bool, completion: @escaping (Bool, Bool) -> Void) {
        guard let helper = proxy(onError: { completion(false, false) }) else { completion(false, false); return }
        helper.heartbeat(externalDisplayConnected: externalDisplayConnected) { active in
            DispatchQueue.main.async { completion(true, active) }
        }
    }
}

/// `--dry-run`: logs every power action and changes nothing.
final class DryRunPowerActions: PowerActions {
    private var holding = false

    func beginHold(completion: @escaping (Bool) -> Void) {
        appLog.notice("[dry-run] would disable sleep via helper and create PreventUserIdleSystemSleep assertion")
        holding = true
        completion(true)
    }

    func endHold(completion: @escaping (Bool) -> Void) {
        appLog.notice("[dry-run] would restore original SleepDisabled and release assertion")
        holding = false
        completion(true)
    }

    func sleepNow() {
        appLog.notice("[dry-run] would put the Mac to sleep")
    }

    func heartbeat(externalDisplayConnected: Bool, completion: @escaping (Bool, Bool) -> Void) {
        completion(true, holding)
    }
}

/// Registers the privileged helper with `SMAppService`.
enum HelperRegistration {
    enum Status: Equatable {
        case enabled, requiresApproval, notRegistered, notFound, unknown
    }

    static var service: SMAppService { SMAppService.daemon(plistName: HelperIdentity.launchdPlistName) }

    static var status: Status {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    /// Only call this from /Applications (see `AppLocation`).
    static func register() throws {
        try service.register()
        UserDefaults.standard.set(bundledHelperFingerprint, forKey: fingerprintKey)
    }

    // An ad-hoc signed helper is registered with a launch constraint that pins
    // its exact cdhash. After an app update, the new helper binary has a
    // different cdhash and launchd refuses to start it (EX_CONFIG). Seen on
    // real hardware, 2026-10-17. Re-registering records the new hash. With a
    // Developer ID, the constraint pins the Team ID and updates keep working.
    private static let fingerprintKey = "registeredHelperFingerprint"

    static var bundledHelperFingerprint: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/HibermateHelper")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The running helper answered, so this binary is the approved one.
    static func recordCurrentFingerprint() {
        UserDefaults.standard.set(bundledHelperFingerprint, forKey: fingerprintKey)
    }

    static var helperChangedSinceRegistration: Bool {
        UserDefaults.standard.string(forKey: fingerprintKey) != bundledHelperFingerprint
    }

    /// Unregisters and registers again. macOS may ask for Login Items approval again.
    static func reregister() async {
        appLog.notice("Re-registering the helper (the bundled helper changed or isn't responding)")
        do { try await service.unregister() } catch {
            appLog.error("Helper unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        do { try register() } catch {
            // Usually "Operation not permitted": registered, but waiting for the
            // user's approval in Login Items. Record the fingerprint anyway, so the
            // next launch doesn't unregister again and clear the pending approval.
            UserDefaults.standard.set(bundledHelperFingerprint, forKey: fingerprintKey)
            appLog.error("Helper register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func unregister() async throws {
        try await service.unregister()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum AppLocation {
    /// The helper may be registered only when the app runs from /Applications
    /// and macOS App Translocation is not in effect.
    static var isInApplications: Bool {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard url.path == "/Applications/Hibermate.app" else { return false }
        return !isTranslocated(url)
    }

    static func isTranslocated(_ url: URL) -> Bool {
        // Translocated apps run from a randomized read-only mount under /private/var/folders/.../AppTranslocation/.
        url.path.contains("/AppTranslocation/")
    }
}
