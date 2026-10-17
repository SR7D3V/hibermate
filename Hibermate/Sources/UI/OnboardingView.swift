import AppKit
import HibermateCore
import SwiftUI

/// First-run setup. It explains exactly what changes on the system and asks
/// for consent to each part separately.
struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @State private var integrationError: String?
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Close the lid. Your agents keep working.").font(.title2.bold())
            Text("Hibermate keeps your Mac awake with the lid closed only while an AI agent is working, then lets it sleep. When nothing is working, your Mac behaves exactly as if Hibermate weren't installed.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Hardware safety (always on)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("• Releases immediately if macOS reports serious or critical heat, and sooner on fanless Macs.")
                    Text("• Releases when the battery falls to \(controller.settings.batteryThreshold)%, and limits holds in Low Power Mode.")
                    Text("• Never holds longer than the maximum (default 4 h, hard limit 12 h).")
                    Text("• If Hibermate crashes, normal sleep returns within 2 minutes.")
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Step 1 — Sleep helper") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A small privileged helper is needed to keep the Mac awake with the lid closed (it runs `pmset disablesleep`). It can only turn that setting on, restore your original value, or put the Mac to sleep.")
                        .fixedSize(horizontal: false, vertical: true)
                    helperStep
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Step 2 — Choose which AI tools to watch") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.integrations, id: \.id) { integration in
                        integrationRow(integration)
                    }
                    Text("Local models (Ollama, llama.cpp, MLX, LM Studio…) and tools without hooks can be watched by activity in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let integrationError {
                        Text(integrationError).foregroundStyle(.red).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(refresh)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    @ViewBuilder private var helperStep: some View {
        switch controller.setup {
        case .wrongLocation:
            Text("Hibermate is running from \(Bundle.main.bundleURL.deletingLastPathComponent().path). Please drag it into your Applications folder and open it from there.")
                .foregroundStyle(.orange)
            Button("Quit") { NSApp.terminate(nil) }
        case .helperNotRegistered:
            Button("Install helper") { controller.registerHelper() }
        case .helperNeedsApproval:
            Text("macOS needs your approval: turn on Hibermate in System Settings → General → Login Items & Extensions. Until then, Hibermate doesn't keep anything awake.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items Settings") { HelperRegistration.openLoginItemsSettings() }
        case .helperUnreachable:
            Text("The helper is installed but not responding. This can happen after updating an unsigned build. Reinstalling it fixes this; macOS may ask you to approve it in Login Items again.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Reinstall helper") { controller.reinstallHelper() }
        case .ready:
            Label(controller.dryRun ? "Dry run: no helper needed" : "Helper installed and approved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func integrationRow(_ integration: AgentIntegration) -> some View {
        let enabled = integration.isEnabled()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(integration.displayName).bold()
                if !integration.isToolPresent { Text("not found on this Mac").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(enabled ? "Disable" : "Enable") {
                    do {
                        if enabled { try integration.disable() } else { try integration.enable() }
                        integrationError = nil
                    } catch {
                        integrationError = "\(integration.displayName): \(Self.describe(error))"
                    }
                    refresh += 1
                }
                .disabled(!integration.isToolPresent && !enabled)
            }
            Text(integration.changeSummary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? ClaudeSettingsError {
        case .corrupt(let why): "Your settings file isn't valid JSON (\(why)). Hibermate won't edit it; please fix it first."
        case .unexpectedShape(let why): "Your settings file has an unexpected layout (\(why)). Hibermate won't edit it."
        case .claudeDirectoryMissing: "The tool's settings folder wasn't found."
        case .concurrentModification: "The settings file changed while Hibermate was editing it. Please try again."
        case .io(let why): why
        case nil: error.localizedDescription
        }
    }
}
