import AppKit
import HibermateCore
import SwiftUI

@main
struct HibermateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(controller: delegate.controller)
        } label: {
            MenuBarLabel(controller: delegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window("Hibermate", id: "main") {
            HibermateWindow(controller: delegate.controller)
        }
        .defaultSize(width: 760, height: 560)

        Window("Welcome to Hibermate", id: "onboarding") {
            OnboardingView(controller: delegate.controller)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
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
        MenuBarIcon(icon: controller.snapshot.icon, updateAvailable: controller.updates.availableUpdate != nil)
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
    var updateAvailable = false

    var body: some View {
        if updateAvailable, let base = baseImage {
            Image(nsImage: Self.withUpdateDot(base))
        } else {
            switch icon {
            case .idle: Image("MenuBarSleeping")
            case .holding: Image("MenuBarAwake")
            case .grace: Image(systemName: "hourglass")
            case .warning: Image(systemName: "exclamationmark.triangle")
            case .setupNeeded: Image(systemName: "gearshape")
            }
        }
    }

    // Bear template images (scripts/icons/render-icons.swift): asleep when
    // the Mac may sleep normally, one eye open while keeping it awake.
    private var baseImage: NSImage? {
        switch icon {
        case .idle: NSImage(named: "MenuBarSleeping")
        case .holding: NSImage(named: "MenuBarAwake")
        case .grace: NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        case .warning: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        case .setupNeeded: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        }
    }

    /// The icon with a small green dot in its top-right corner. A template
    /// image can't carry color, so the icon is drawn in the menu bar's label
    /// color at draw time, which follows light and dark menu bars.
    static func withUpdateDot(_ base: NSImage) -> NSImage {
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = NSImage(size: size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: rect)
            let d: CGFloat = 6.5
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            // Cut a thin gap around the dot so it reads against the glyph.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Hibermate, update available"
        return image
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
