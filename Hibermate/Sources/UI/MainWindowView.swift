import AppKit
import HibermateCore
import SwiftUI

/// The main window: everything in the menu, plus why Hibermate is doing what it does.
struct MainWindowView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = controller.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(s)
                if !s.warnings.isEmpty {
                    card("Attention") {
                        ForEach(s.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                card("Sessions") {
                    if s.sessions.isEmpty {
                        Text("No AI tools are working right now. Start a prompt in a tool you've enabled, and it shows up here.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(s.sessions) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.body.weight(.medium))
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                card("This Mac") {
                    row("thermometer.medium", s.thermal)
                    row("battery.50", s.battery)
                    row("laptopcomputer", s.lid)
                    row("display", s.display)
                    row("moon.zzz", s.otherApps)
                    if let left = s.timeRemaining { row("timer", left) }
                }
                card("Recent safety releases") {
                    if s.recentReleases.isEmpty {
                        Text("None. Hibermate hasn't had to stop early to protect your Mac.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(s.recentReleases) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                Text(r.summary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if s.notificationsAllowed == false {
                        Label("Notifications are off, so you won't be told as it happens.", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Turn on notifications…") { Notifier.openSettings() }
                    }
                }
                card("Watching") {
                    let enabled = controller.integrations.filter { $0.isEnabled() }.map(\.displayName)
                    let watched = ActivityCatalog.tools.filter { controller.settings.watchedTools.contains($0.id.rawValue) }
                        .map(\.displayName)
                    if enabled.isEmpty && watched.isEmpty {
                        Text("No AI tools are enabled yet, so Hibermate never keeps the Mac awake.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !enabled.isEmpty { row("link", "Hooks: " + enabled.joined(separator: ", ")) }
                    if !watched.isEmpty { row("waveform.path.ecg", "Activity: " + watched.joined(separator: ", ")) }
                    Button("Choose tools…") { show("onboarding") }
                }
                actions(s)
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 480)
    }

    private func header(_ s: MenuSnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.headline).font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(s.explanation).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actions(_ s: MenuSnapshot) -> some View {
        HStack {
            Button("Release now") { controller.releaseNow() }
                .disabled(!s.isActive)
            if s.isPaused {
                Button("Resume") { controller.resume() }
            } else {
                Button("Pause for 1 hour") { controller.pauseOneHour() }
            }
            Spacer()
            if controller.setup != .ready {
                Button("Finish setup…") { show("onboarding") }
                    .buttonStyle(.borderedProminent)
            }
            Button("Settings…") { show("settings") }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            Text(title).font(.headline)
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
