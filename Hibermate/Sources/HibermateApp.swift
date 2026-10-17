import AppKit
import HibermateCore
import SwiftUI

@main
struct HibermateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            MenuBarIcon(icon: delegate.controller.snapshot.icon)
        }
        .menuBarExtraStyle(.menu)

        Window("Hibermate Settings", id: "settings") {
            SettingsView(controller: delegate.controller)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Hibermate", id: "onboarding") {
            OnboardingView(controller: delegate.controller)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController(dryRun: CommandLine.arguments.contains("--dry-run"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        if controller.settings.notificationsEnabled { Notifier.requestAuthorization() }
    }

    /// Quitting must release everything cleanly before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.shutdown {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuBarIcon: View {
    let icon: MenuSnapshot.Icon

    var body: some View {
        // SF Symbols until the bear template image exists.
        switch icon {
        case .idle: Image(systemName: "moon.zzz")
        case .holding: Image(systemName: "eye")
        case .grace: Image(systemName: "hourglass")
        case .warning: Image(systemName: "exclamationmark.triangle")
        case .setupNeeded: Image(systemName: "gearshape")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = controller.snapshot
        Text(s.headline)
        if controller.setup != .ready {
            Button("Finish setup…") { show("onboarding") }
        }
        Divider()
        if s.sessions.isEmpty {
            Text("No active sessions")
        } else {
            ForEach(s.sessions) { row in
                Text("\(row.title)  (\(row.detail))")
            }
        }
        Divider()
        Text(s.thermal)
        Text(s.battery)
        if let left = s.timeRemaining { Text(left) }
        ForEach(s.warnings, id: \.self) { Text("⚠︎ \($0)") }
        Divider()
        Button("Release now") { controller.releaseNow() }
            .disabled(!s.isActive)
        if s.isPaused {
            Button("Resume Hibermate") { controller.resume() }
        } else {
            Button("Pause Hibermate for 1 hour") { controller.pauseOneHour() }
        }
        Divider()
        Button("Settings…") { show("settings") }
            .keyboardShortcut(",")
        Button("Uninstall Hibermate…") { show("settings") }
        Button("Quit Hibermate") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
