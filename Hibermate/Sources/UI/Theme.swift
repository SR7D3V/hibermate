import HibermateCore
import SwiftUI

/// Hibermate's visual language: quiet rounded cards, small uppercase section
/// titles, monochrome icons, and color only where it carries meaning
/// (status dots, temperature).
enum Theme {
    static let cardCorner: CGFloat = 14
    static let cardFill = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.07)
    static let iconFill = Color.primary.opacity(0.07)

    static func color(for status: MenuSnapshot.SessionRow.Status) -> Color {
        switch status {
        case .working: .green
        case .waiting, .timedOut: .orange
        case .background: .blue
        case .idle: .gray
        }
    }

    static func thermalColor(_ level: ThermalLevel) -> Color {
        switch level {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    /// The tool's logo in the asset catalog (Simple Icons, CC0; see
    /// docs/THIRD_PARTY.md), or nil to use `agentSymbol`.
    static func agentLogo(_ id: AgentID) -> String? {
        let withLogos: Set<String> = ["claude-code", "gemini", "qwen", "copilot", "cursor", "opencode"]
        return withLogos.contains(id.rawValue) ? "Logo-\(id.rawValue)" : nil
    }

    /// A generic symbol per tool, used when there's no logo.
    static func agentSymbol(_ id: AgentID) -> String {
        switch id.rawValue {
        case "claude-code": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "diamond"
        case "qwen": "circle.hexagongrid"
        case "copilot": "airplane"
        case "cursor": "cursorarrow.rays"
        case "opencode": "curlybraces"
        case "generic": "terminal"
        default: "cpu" // local models and other watched tools
        }
    }
}

// MARK: - Containers

/// "KEEP AWAKE"-style heading above a card.
struct SectionTitle: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 4)
    }
}

/// A rounded card. Rows inside are separated with `RowDivider`.
struct Card<Content: View>: View {
    var title: String?
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.headline)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

struct RowDivider: View {
    var inset: CGFloat = 16
    var body: some View { Divider().padding(.leading, inset).padding(.trailing, 16) }
}

/// Icon + title + optional gray description + trailing control.
struct SettingRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol { RowIcon(symbol: symbol) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// A monochrome symbol or logo in a subtle rounded square.
struct RowIcon: View {
    let symbol: String
    var logo: String?
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Theme.iconFill)
            .frame(width: size, height: size)
            .overlay {
                if let logo {
                    Image(logo).resizable().renderingMode(.template).scaledToFit()
                        .frame(width: size * 0.5, height: size * 0.5)
                        .foregroundStyle(.primary.opacity(0.85))
                } else {
                    Image(systemName: symbol).font(.system(size: size * 0.46)).foregroundStyle(.secondary)
                }
            }
    }
}

/// A tool's logo (or symbol) at text size, for compact rows.
struct AgentGlyph: View {
    let agent: AgentID
    var size: CGFloat = 16

    var body: some View {
        if let logo = Theme.agentLogo(agent) {
            Image(logo).resizable().renderingMode(.template).scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: Theme.agentSymbol(agent)).foregroundStyle(.secondary)
        }
    }
}

/// Label left, value right, for compact readings.
struct ValueRow: View {
    let label: String
    let value: String
    var symbol: String?
    var dot: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(value).fontWeight(.semibold)
        }
    }
}

/// "● Working" style status text.
struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Chips and buttons

/// A grid of selectable duration chips (15m, 30m, 1h…).
struct ChipGrid<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value?
    var columns = 4
    let onSelect: (Value) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Button { onSelect(value) } label: {
                    Text(label)
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(selected ? 0.16 : 0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(selected ? 0.35 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The wide, equal footer buttons in the menu bar panel.
struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The bear mark, asleep or with one eye open.
struct BearMark: View {
    let awake: Bool
    var size: CGFloat = 30

    var body: some View {
        Image(awake ? "MenuBarAwake" : "MenuBarSleeping")
            .resizable()
            .renderingMode(.template)
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
    }
}

/// One session row: project, tool and time, status dot.
struct SessionRowView: View {
    let row: MenuSnapshot.SessionRow

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(agent: row.agent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.project).fontWeight(.medium).lineLimit(1)
                Text("\(row.agentName) · \(row.elapsed)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusDot(text: row.statusText, color: Theme.color(for: row.status))
        }
    }
}

/// A page heading in the Settings window: big title, gray subtitle.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

/// Shows the snapshot's subtitle; during grace it re-renders once a second,
/// on the second boundary, so the countdown steps through every number.
struct LiveSubtitle<Content: View>: View {
    let snapshot: MenuSnapshot
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        if let end = snapshot.graceEndsAt {
            let remaining = end - ProcessInfo.processInfo.systemUptime
            // Tick just after each whole second so rounding up never wobbles.
            let phase = remaining - remaining.rounded(.down) + 0.05
            TimelineView(.periodic(from: Date().addingTimeInterval(phase), by: 1)) { _ in
                content(AppController.graceSubtitle(remaining: end - ProcessInfo.processInfo.systemUptime))
            }
        } else {
            content(snapshot.subtitle)
        }
    }
}
