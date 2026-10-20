import AppKit
import HibermateCore
import SwiftUI

/// The menu bar panel: the bear, then STATUS, SESSIONS and THIS MAC cards,
/// and two footer buttons.
struct MenuPanelView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = controller.snapshot
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topTrailing) {
                HStack { Spacer(); BearMark(awake: s.icon == .holding || s.icon == .grace, size: 34); Spacer() }
                    .padding(.top, 4)
                if let update = controller.updates.availableUpdate {
                    Button {
                        NSWorkspace.shared.open(update.releasePage)
                        dismiss()
                    } label: {
                        Text("UPDATE").font(.caption.weight(.bold)).tracking(0.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.green))
                    }
                    .buttonStyle(.plain)
                    .help("Hibermate \(update.version) is available. Opens the download page.")
                }
            }

            if controller.setup != .ready {
                notice("Finish setup to keep your Mac awake", symbol: "gearshape") { open(.general) }
            } else if let warning = s.warnings.first {
                notice(warning, symbol: "exclamationmark.triangle", color: .orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "Status")
                Card {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.headline).font(.body.weight(.semibold))
                            LiveSubtitle(snapshot: s) { Text($0).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { !s.isPaused },
                                                 set: { $0 ? controller.resume() : controller.pause(for: nil) }))
                            .toggleStyle(.switch).labelsHidden()
                            .help(s.isPaused ? "Resume Hibermate" : "Turn Hibermate off until you turn it back on")
                    }
                    .padding(14)
                    if !s.isPaused {
                        RowDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pause for").font(.callout).foregroundStyle(.secondary)
                            ChipGrid(options: [(3600.0, "1h"), (4 * 3600.0, "4h"), (8 * 3600.0, "8h"), (-1.0, "Release")],
                                     selection: nil, columns: 4) { value in
                                if value < 0 { controller.releaseNow() } else { controller.pause(for: value) }
                            }
                        }
                        .padding(14)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "Sessions", trailing: s.sessions.isEmpty ? nil : "\(s.sessions.filter(\.holds).count) working")
                Card {
                    if s.sessions.isEmpty {
                        Text("No AI tools working").foregroundStyle(.secondary).padding(14)
                    } else {
                        ForEach(Array(s.sessions.prefix(4).enumerated()), id: \.element.id) { i, row in
                            if i > 0 { RowDivider(inset: 42) }
                            SessionRowView(row: row).padding(.horizontal, 14).padding(.vertical, 9)
                        }
                        if s.sessions.count > 4 {
                            RowDivider()
                            Button("Show all \(s.sessions.count)") { open(.overview) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).padding(12)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "This Mac")
                Card {
                    VStack(spacing: 9) {
                        ValueRow(label: "Temperature", value: s.thermalLevel.plainDescription,
                                 symbol: "thermometer.medium", dot: Theme.thermalColor(s.thermalLevel))
                        ValueRow(label: "Battery", value: s.batteryShort == "Power" ? "Plugged in" : s.batteryShort,
                                 symbol: "battery.75percent")
                        if let left = s.timeLeftShort {
                            ValueRow(label: "Hold ends in", value: left, symbol: "timer")
                        }
                    }
                    .padding(14)
                }
            }

            HStack(spacing: 10) {
                FooterButton(title: "Settings", symbol: "gearshape") { open(controller.page) }
                    .keyboardShortcut(",")
                FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func notice(_ text: String, symbol: String, color: Color = .orange, action: (() -> Void)? = nil) -> some View {
        let content = HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if action != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(color.opacity(0.12)))
        return Button { action?() } label: { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(action == nil)
    }

    private func open(_ page: MainPage) {
        controller.page = page
        dismiss()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
