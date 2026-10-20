// HibermateHelper: the privileged launchd daemon, registered by the app with
// SMAppService.daemon. It can only toggle SleepDisabled (restoring the user's
// original value) and request sleep. Everything else is refused.

import Darwin
import Foundation
import HibermateHelperKit

/// All state changes run on this queue: XPC calls, timers, and signals.
let queue = DispatchQueue(label: "com.sr7d3v.hibermate.helper")

let core = HelperCore(
    control: SystemSleepControl(),
    store: FileHelperStateStore(),
    clock: { ProcessInfo.processInfo.systemUptime },
    appLoss: HelperCore.AppLossSleep(
        lidClosed: { SystemSleep.lidClosed() },
        sleep: { _ = SystemSleep.sleepNow() }
    )
)

final class HelperService: NSObject, HibermateHelperXPC {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool) -> Void) {
        queue.async {
            do {
                try core.setSleepDisabled(disabled)
                reply(true)
            } catch {
                helperLog.error("setSleepDisabled(\(disabled, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                reply(false)
            }
        }
    }

    func sleepNow(reply: @escaping (Bool) -> Void) {
        queue.async { reply(SystemSleep.sleepNow()) }
    }

    func heartbeat(externalDisplayConnected: Bool, reply: @escaping (Bool) -> Void) {
        queue.async {
            core.heartbeat(externalDisplayConnected: externalDisplayConnected)
            reply(core.holdActive)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 1. Code signature: the system checks it against the caller's audit token.
        connection.setCodeSigningRequirement(HelperIdentity.callerRequirement)
        // 2. Location: the caller's executable must be the installed app.
        //    This guards against casual spoofing while builds are ad-hoc signed.
        guard Self.executablePath(of: connection.processIdentifier) == HelperIdentity.appExecutablePath else {
            helperLog.error("Rejected XPC connection from pid \(connection.processIdentifier, privacy: .public)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: HibermateHelperXPC.self)
        connection.exportedObject = HelperService()
        // The app crashed or quit: restore right away instead of waiting for the dead-man deadline.
        connection.invalidationHandler = {
            queue.async { core.connectionInvalidated() }
        }
        connection.resume()
        return true
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }
}

// A hold interrupted by a crash or reboot: restore normal behavior first.
queue.sync { core.reconcileOnStart() }

// Dead-man switch: check every 10 s for missed heartbeats.
let ticker = DispatchSource.makeTimerSource(queue: queue)
ticker.schedule(deadline: .now() + 10, repeating: 10)
ticker.setEventHandler { core.tick() }
ticker.resume()

// launchd sends SIGTERM on unregistration, uninstall, and shutdown. Restore, then exit.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
termSource.setEventHandler {
    core.terminate()
    exit(0)
}
termSource.resume()

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
