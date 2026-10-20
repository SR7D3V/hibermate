import AppKit
import HibermateCore
import SwiftUI

/// First-run setup in three short steps: what Hibermate does, the helper, and
/// which AI tools to watch. Each step asks for consent to one change.
struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0: welcome
                    case 1: helper
                    default: tools
                    }
                }
                .padding(28)
            }

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i == step ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: step)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Done" : "Continue") {
                    if step == 2 { dismiss() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(step == 1 && controller.setup == .wrongLocation)
            }
            .padding(16)
        }
        .frame(width: 540, height: 520)
        .onAppear { controller.refreshIntegrations() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Spacer(); Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88); Spacer() }
            PageHeader(title: "Close the lid. Your agents keep working.",
                       subtitle: "Hibermate keeps your Mac awake with the lid closed only while an AI tool is working, then lets it sleep.")
            Card {
                SettingRow(symbol: "thermometer.medium", title: "Stops if the Mac gets hot") { EmptyView() }
                RowDivider(inset: 58)
                SettingRow(symbol: "battery.25percent", title: "Stops when the battery runs low") { EmptyView() }
                RowDivider(inset: 58)
                SettingRow(symbol: "timer", title: "Never holds longer than your limit (default 4 h)") { EmptyView() }
                RowDivider(inset: 58)
                SettingRow(symbol: "arrow.uturn.backward", title: "If anything crashes, normal sleep returns within 2 minutes") { EmptyView() }
            }
        }
    }

    private var helper: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Install the sleep helper",
                       subtitle: "Keeping a Mac awake with the lid closed needs a small system helper. It can only turn lid-closed sleep off, restore your original setting, or put the Mac to sleep.")
            Card { HelperStatusRow(controller: controller) }
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Choose your AI tools",
                       subtitle: "Turn on the tools you use. You can change this any time in Settings → AI tools.")
            let present = controller.integrations.filter { $0.isToolPresent || controller.enabledIntegrations.contains($0.id) }
            Card {
                if present.isEmpty {
                    Text("No supported AI tools found on this Mac yet.").foregroundStyle(.secondary).padding(16)
                }
                ForEach(Array(present.enumerated()), id: \.element.id) { i, integration in
                    if i > 0 { RowDivider(inset: 58) }
                    AgentRow(integration: integration, controller: controller)
                }
            }
            if let error = controller.integrationError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
    }
}
