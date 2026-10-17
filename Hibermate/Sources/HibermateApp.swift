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
            MenuBarLabel(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Window("Hibermate", id: "main") {
            MainWindowView(controller: delegate.controller)
        }
        .defaultSize(width: 520, height: 620)

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

/// The menu bar label. It also opens the setup window on first launch, and
/// on any launch where setup is incomplete.
struct MenuBarLabel: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("onboardingShown") private var onboardingShown = false

    var body: some View {
        MenuBarIcon(icon: controller.snapshot.icon)
            .task {
                // Give the first tick a moment to work out the setup state.
                try? await Task.sleep(for: .seconds(1))
                if !onboardingShown || controller.setup != .ready {
                    onboardingShown = true
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

struct MenuBarIcon: View {
    let icon: MenuSnapshot.Icon

    var body: some View {
        // Bear template images (scripts/icons/render-icons.swift): asleep when
        // the Mac may sleep normally, one eye open while keeping it awake.
        switch icon {
        case .idle: Image("MenuBarSleeping")
        case .holding: Image("MenuBarAwake")
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
        Button("Open Hibermate…") { show("main") }
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
        Button("Uninstall Hibermate…") { Uninstaller.confirmAndRun(controller) }
        Button("Quit Hibermate") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
enum Uninstaller {
    static func confirmAndRun(_ controller: AppController) {
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Uninstall Hibermate?"
        confirm.informativeText = """
            This restores your original sleep setting, removes Hibermate's hooks from every AI tool \
            (each settings file is backed up first), removes the helper, and deletes Hibermate's data.
            """
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        controller.uninstall { result in
            let done = NSAlert()
            done.messageText = result.failures.isEmpty ? "Hibermate has been removed" : "Hibermate was mostly removed"
            var text = result.removedIntegrations.isEmpty ? "" :
                "Removed hooks from: \(result.removedIntegrations.joined(separator: ", ")).\n\n"
            if !result.failures.isEmpty { text += "Some steps need attention:\n" + result.failures.joined(separator: "\n") + "\n\n" }
            text += "Move Hibermate.app to the Trash to finish."
            done.informativeText = text
            done.addButton(withTitle: "Move to Trash and Quit")
            done.addButton(withTitle: "Quit")
            if done.runModal() == .alertFirstButtonReturn, !controller.dryRun {
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
                    DispatchQueue.main.async { exit(0) }
                }
            } else {
                exit(0)
            }
        }
    }
}
