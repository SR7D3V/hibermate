import HibermateCore
import ServiceManagement
import SwiftUI

/// Safety settings only offer values inside the allowed ranges, and the
/// engine clamps again regardless. There is no switch to turn off thermal protection.
struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Hold limits") {
                minutes("Maximum hold", \.maxHold, range: SafetyLimits.maxHoldMinimum...SafetyLimits.maxHoldHardCeiling,
                        step: 15 * 60, note: "Default 4 h. Hard limit 12 h.")
                seconds("Grace period after work ends", \.gracePeriod, range: SafetyLimits.graceRange, step: 15,
                        note: "Covers the gap between queued prompts.")
            }
            Section("Safety (can only be made stricter)") {
                Stepper(value: $controller.settings.batteryThreshold, in: SafetyLimits.batteryThresholdRange, step: 5) {
                    LabeledContent("Release at battery", value: "\(controller.settings.batteryThreshold)%")
                }
                minutes("Release after staying warm", fairTimeoutBinding,
                        range: SafetyLimits.fairTimeoutMinimum...SafetyLimits.fairTimeoutDefault(fanless: controller.isFanless),
                        step: 60, note: controller.isFanless ? "This Mac has no fan: 5 min maximum." : "10 min maximum.")
                minutes("Stop waiting for a permission answer after", \.permissionWait,
                        range: SafetyLimits.permissionWaitRange, step: 60, note: nil)
                minutes("Treat a silent session as finished after", \.staleWindow,
                        range: SafetyLimits.staleWindowRange, step: 60, note: nil)
                Text("Thermal protection is always on. These limits are Hibermate's own design choices; Apple doesn't publish internal temperature limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Notifications for safety releases", isOn: $controller.settings.notificationsEnabled)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical)
    }

    private var fairTimeoutBinding: WritableKeyPath<UserSettings, TimeInterval> { \.fairTimeoutOrDefault }

    private func minutes(_ label: String, _ key: WritableKeyPath<UserSettings, TimeInterval>,
                         range: ClosedRange<TimeInterval>, step: TimeInterval, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: binding(key, range), in: range, step: step) {
                LabeledContent(label, value: AppController.format(controller.settings[keyPath: key]))
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func seconds(_ label: String, _ key: WritableKeyPath<UserSettings, TimeInterval>,
                         range: ClosedRange<TimeInterval>, step: TimeInterval, note: String?) -> some View {
        minutes(label, key, range: range, step: step, note: note)
    }

    private func binding(_ key: WritableKeyPath<UserSettings, TimeInterval>, _ range: ClosedRange<TimeInterval>) -> Binding<TimeInterval> {
        Binding(
            get: { min(max(controller.settings[keyPath: key], range.lowerBound), range.upperBound) },
            set: { controller.settings[keyPath: key] = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

extension UserSettings {
    /// The `.fair` timeout for the stepper, where nil means the model default.
    var fairTimeoutOrDefault: TimeInterval {
        get { fairTimeout ?? SafetyLimits.fairTimeoutWithFans }
        set { fairTimeout = newValue }
    }
}
