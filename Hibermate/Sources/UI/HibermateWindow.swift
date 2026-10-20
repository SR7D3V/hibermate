import AppKit
import HibermateCore
import ServiceManagement
import SwiftUI

/// Hibermate's Settings window: a grouped sidebar and one scrolling page.
struct HibermateWindow: View {
    @ObservedObject var controller: AppController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { controller.page }, set: { if let p = $0 { controller.page = p } })) {
                Section("Hibermate") {
                    sidebarItem(.overview, "moon.zzz")
                    sidebarItem(.agents, "sparkles")
                    sidebarItem(.safety, "shield.lefthalf.filled")
                }
                Section("App") {
                    sidebarItem(.general, "gearshape")
                    sidebarItem(.about, "info.circle")
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch controller.page {
                    case .overview: OverviewPage(controller: controller)
                    case .agents: AgentsPage(controller: controller)
                    case .safety: SafetyPage(controller: controller)
                    case .general: GeneralPage(controller: controller)
                    case .about: AboutPage(controller: controller)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Hibermate Settings")
        .frame(minWidth: 760, minHeight: 540)
        .onAppear { controller.refreshIntegrations() }
    }

    private func sidebarItem(_ page: MainPage, _ symbol: String) -> some View {
        Label(page.title, systemImage: symbol)
            .tag(page)
            .badge(page == .general && controller.setup != .ready ? 1 : 0)
    }
}

// MARK: - Status

struct OverviewPage: View {
    @ObservedObject var controller: AppController

    var body: some View {
        let s = controller.snapshot
        PageHeader(title: "Status", subtitle: s.explanation)

        Card {
            SettingRow(symbol: s.isActive ? "eye" : "moon.zzz", title: s.headline, subtitle: s.subtitle) {
                Toggle("", isOn: Binding(get: { !s.isPaused },
                                         set: { $0 ? controller.resume() : controller.pause(for: nil) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if s.isActive {
                RowDivider()
                SettingRow(symbol: "moon", title: "Release now", subtitle: "Let the Mac sleep normally until the current work finishes.") {
                    Button("Release") { controller.releaseNow() }
                }
            }
            ForEach(s.warnings, id: \.self) { w in
                RowDivider()
                SettingRow(symbol: "exclamationmark.triangle", title: w) { EmptyView() }
                    .foregroundStyle(.orange)
            }
        }

        SectionTitle(text: "Sessions", trailing: s.sessions.isEmpty ? nil : "\(s.sessions.filter(\.holds).count) working")
        Card {
            if s.sessions.isEmpty {
                Text("No AI tools are working.").foregroundStyle(.secondary).padding(16)
            } else {
                ForEach(Array(s.sessions.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { RowDivider(inset: 44) }
                    SessionRowView(row: row).padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }

        SectionTitle(text: "This Mac")
        Card {
            VStack(spacing: 10) {
                ValueRow(label: "Temperature", value: s.thermalLevel.plainDescription, symbol: "thermometer.medium",
                         dot: Theme.thermalColor(s.thermalLevel))
                ValueRow(label: "Battery", value: s.batteryShort == "Power" ? "Plugged in" : s.batteryShort, symbol: "battery.75percent")
                ValueRow(label: "Lid", value: s.lid.replacingOccurrences(of: "Lid: ", with: "").capitalized, symbol: "laptopcomputer")
                ValueRow(label: "Hold ends in", value: s.timeLeftShort ?? "—", symbol: "timer")
            }
            .padding(16)
        }

        SectionTitle(text: "Recent safety releases")
        Card {
            if s.recentReleases.isEmpty {
                Text("None. Hibermate hasn't had to stop early to protect your Mac.").foregroundStyle(.secondary).padding(16)
            } else {
                ForEach(Array(s.recentReleases.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { RowDivider() }
                    SettingRow(title: r.summary, subtitle: r.date.formatted(date: .abbreviated, time: .shortened)) { EmptyView() }
                }
            }
        }
    }
}

// MARK: - AI tools

struct AgentsPage: View {
    @ObservedObject var controller: AppController
    @State private var showMissing = false

    var body: some View {
        let present = controller.integrations.filter { $0.isToolPresent || controller.enabledIntegrations.contains($0.id) }
        let missing = controller.integrations.filter { !$0.isToolPresent && !controller.enabledIntegrations.contains($0.id) }
        PageHeader(title: "AI tools",
                   subtitle: "Turn on the tools you use. Their hooks only report when work starts and stops — never your prompts, code, or transcripts.")

        Card {
            HStack {
                Text("\(controller.enabledIntegrations.count) of \(present.count) tools on").font(.headline)
                Spacer()
            }
            .padding(16)
            ProgressView(value: Double(controller.enabledIntegrations.count), total: Double(max(present.count, 1)))
                .tint(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 16)
        }

        SectionTitle(text: "Installed on this Mac")
        Card {
            if present.isEmpty {
                Text("No supported AI tools found on this Mac.").foregroundStyle(.secondary).padding(16)
            }
            ForEach(Array(present.enumerated()), id: \.element.id) { i, integration in
                if i > 0 { RowDivider(inset: 58) }
                AgentRow(integration: integration, controller: controller)
            }
            if let error = controller.integrationError {
                RowDivider()
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !missing.isEmpty {
            Card {
                Button { withAnimation { showMissing.toggle() } } label: {
                    HStack {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(showMissing ? 90 : 0))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Not installed").fontWeight(.medium)
                        Spacer()
                        Text("\(missing.count)").foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showMissing {
                    ForEach(missing, id: \.id) { integration in
                        RowDivider(inset: 58)
                        AgentRow(integration: integration, controller: controller)
                    }
                }
            }
        }

        SectionTitle(text: "Local models and tools without hooks")
        Card {
            ForEach(Array(ActivityCatalog.tools.enumerated()), id: \.element.id) { i, tool in
                if i > 0 { RowDivider(inset: 58) }
                SettingRow(symbol: Theme.agentSymbol(tool.id), title: tool.displayName,
                           subtitle: tool.kind == .localModel ? "Local model · watched by CPU and GPU use" : "Command line · watched by CPU use") {
                    Toggle("", isOn: watchBinding(tool.id)).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        Text("A loaded but idle model doesn't keep the Mac awake. Off by default.")
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
    }

    private func watchBinding(_ id: AgentID) -> Binding<Bool> {
        Binding(
            get: { controller.settings.watchedTools.contains(id.rawValue) },
            set: { on in
                controller.settings.watchedTools.removeAll { $0 == id.rawValue }
                if on { controller.settings.watchedTools.append(id.rawValue) }
            }
        )
    }
}

struct AgentRow: View {
    let integration: AgentIntegration
    @ObservedObject var controller: AppController
    @State private var showInfo = false

    var body: some View {
        let enabled = controller.enabledIntegrations.contains(integration.id)
        HStack(spacing: 12) {
            RowIcon(symbol: Theme.agentSymbol(integration.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.displayName)
                if enabled {
                    StatusDot(text: "On", color: .green)
                } else {
                    Text(integration.isToolPresent ? "Off" : "Not installed").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showInfo.toggle() } label: {
                Text("What changes").font(.callout)
                Image(systemName: "chevron.right").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                Text(integration.changeSummary).font(.callout).padding(14).frame(width: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("", isOn: Binding(get: { enabled }, set: { controller.setIntegration(integration, enabled: $0) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!integration.isToolPresent && !enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Safety

struct SafetyPage: View {
    @ObservedObject var controller: AppController

    var body: some View {
        PageHeader(title: "Safety", subtitle: "How long Hibermate may keep your Mac awake, and when it stops to protect it.")

        Card(title: "Maximum hold") {
            VStack(alignment: .leading, spacing: 10) {
                ChipGrid(options: [(900.0, "15m"), (1800, "30m"), (3600, "1h"), (7200, "2h"),
                                   (14400, "4h"), (21600, "6h"), (28800, "8h"), (43200, "12h")],
                         selection: controller.settings.maxHold) { controller.settings.maxHold = $0 }
                Text("Default 4 hours. Hibermate never holds longer than 12 hours.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
        }

        Card(title: "Grace period") {
            VStack(alignment: .leading, spacing: 10) {
                ChipGrid(options: [(30.0, "30s"), (60, "1m"), (120, "2m"), (300, "5m")],
                         selection: controller.settings.gracePeriod) { controller.settings.gracePeriod = $0 }
                Text("How long to wait after work ends before normal sleep returns. It covers the moment between queued prompts.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }

        SectionTitle(text: "Protection")
        Card {
            SettingRow(symbol: "battery.25percent", title: "Release when the battery reaches", subtitle: "On battery power.") {
                menuPicker(selection: $controller.settings.batteryThreshold,
                           options: Array(stride(from: 20, through: 80, by: 5)).map { ($0, "\($0)%") })
            }
            RowDivider(inset: 58)
            SettingRow(symbol: "thermometer.medium", title: "Release after staying warm for",
                       subtitle: controller.isFanless ? "With the lid closed. This Mac has no fan." : "With the lid closed.") {
                menuPicker(selection: $controller.settings.fairTimeoutOrDefault,
                           options: (controller.isFanless ? [60.0, 120, 180, 240, 300] : [60.0, 120, 180, 300, 420, 600])
                               .map { ($0, AppController.format($0)) })
            }
            RowDivider(inset: 58)
            SettingRow(symbol: "hand.raised", title: "Stop waiting for a permission answer after",
                       subtitle: "Nobody can answer with the lid closed.") {
                menuPicker(selection: $controller.settings.permissionWait,
                           options: [60.0, 120, 180, 240, 300].map { ($0, AppController.format($0)) })
            }
            RowDivider(inset: 58)
            SettingRow(symbol: "zzz", title: "Treat a silent session as finished after", subtitle: nil) {
                menuPicker(selection: $controller.settings.staleWindow,
                           options: [300.0, 600, 900].map { ($0, AppController.format($0)) })
            }
        }
        Text("These can only be made stricter. Heat protection is always on. The limits are Hibermate's own design choices; Apple doesn't publish internal temperature limits.")
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func menuPicker<T: Hashable>(selection: Binding<T>, options: [(T, String)]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            if !options.contains(where: { $0.0 == selection.wrappedValue }) {
                Text("Custom").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

extension UserSettings {
    /// The warm-state timeout for the picker; nil means the model default.
    var fairTimeoutOrDefault: TimeInterval {
        get { fairTimeout ?? SafetyLimits.fairTimeoutWithFans }
        set { fairTimeout = newValue }
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var controller: AppController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        PageHeader(title: "General", subtitle: "The sleep helper, startup, and notifications.")

        Card {
            HelperStatusRow(controller: controller)
        }

        Card {
            SettingRow(symbol: "laptopcomputer", title: "Launch at login", subtitle: "Opens by itself every time you turn on your Mac.") {
                Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            RowDivider(inset: 58)
            SettingRow(symbol: "bell", title: "Safety notifications",
                       subtitle: controller.snapshot.notificationsAllowed == false
                           ? "Turned off in System Settings, so you'll see a note when you return instead."
                           : "Tells you when Hibermate stops early to protect your Mac.") {
                if controller.snapshot.notificationsAllowed == false {
                    Button("Turn On…") { Notifier.openSettings() }
                } else {
                    Toggle("", isOn: $controller.settings.notificationsEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
        }

        SectionTitle(text: "Uninstall")
        Card {
            Text("Restores your sleep setting, removes Hibermate's hooks from every AI tool (keeping backups), removes the helper, deletes its data, and moves Hibermate to the Trash.")
                .font(.callout).foregroundStyle(.secondary).padding(16)
                .fixedSize(horizontal: false, vertical: true)
            RowDivider()
            Button { Uninstaller.confirmAndRun(controller) } label: {
                Label("Uninstall Hibermate completely", systemImage: "trash")
            }
            .padding(16)
        }
    }
}

struct HelperStatusRow: View {
    @ObservedObject var controller: AppController

    var body: some View {
        let (symbol, color, title, detail) = info
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.iconFill).frame(width: 30, height: 30)
                .overlay(Image(systemName: symbol).foregroundStyle(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var info: (String, Color, String, String) {
        switch controller.setup {
        case .ready:
            return ("checkmark.circle.fill", .green, controller.dryRun ? "Sleep helper (dry run)" : "Sleep helper is ready",
                    "Can only turn lid-closed sleep off and back on, and put the Mac to sleep.")
        case .wrongLocation:
            return ("exclamationmark.triangle.fill", .orange, "Move Hibermate to Applications",
                    "It's running from \(Bundle.main.bundleURL.deletingLastPathComponent().path).")
        case .helperNotRegistered:
            return ("circle.dashed", .orange, "Sleep helper not installed",
                    "Needed to keep the Mac awake with the lid closed.")
        case .helperNeedsApproval:
            return ("hand.raised.fill", .orange, "Waiting for your approval",
                    "Turn on Hibermate in System Settings → General → Login Items & Extensions.")
        case .helperUnreachable:
            return ("exclamationmark.triangle.fill", .orange, "Sleep helper not responding",
                    "After an update, approve it again in Login Items, or reinstall it.")
        }
    }

    @ViewBuilder private var action: some View {
        switch controller.setup {
        case .ready: EmptyView()
        case .wrongLocation: Button("Quit") { NSApp.terminate(nil) }
        case .helperNotRegistered: Button("Install") { controller.registerHelper() }.buttonStyle(.borderedProminent)
        case .helperNeedsApproval: Button("Open Login Items") { HelperRegistration.openLoginItemsSettings() }
        case .helperUnreachable:
            Menu("Fix") {
                Button("Open Login Items") { HelperRegistration.openLoginItemsSettings() }
                Button("Reinstall helper") { controller.reinstallHelper() }
            }
            .fixedSize()
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Card {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Hibermate").font(.title.weight(.bold))
                Text("Version \(version)").foregroundStyle(.secondary)
                Text("Close the lid. Your agents keep working.").padding(.top, 6)
                HStack(spacing: 10) {
                    Button("Review setup") { openWindow(id: "onboarding") }
                    Link("View on GitHub", destination: URL(string: "https://github.com/SR7D3V/hibermate")!)
                }
                .padding(.top, 8)
                Text("Free and open source under GPL-3.0 · No network access, no telemetry")
                    .font(.callout).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
}
