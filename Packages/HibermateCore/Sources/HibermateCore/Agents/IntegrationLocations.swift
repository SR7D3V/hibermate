import Foundation

/// Every file outside its own folder that Hibermate may change, in one place.
/// The app's integrations and the uninstaller both use this list, so uninstall
/// can never miss a location that install wrote to.
public struct HookIntegrationLocation: Sendable {
    public var displayName: String
    public var file: HookConfigFile
    /// The tool's config folder. Its presence means the tool is installed.
    public var toolDirectory: URL
    public var note: String?
}

public enum IntegrationLocations {
    public static func hookFiles(home: URL = HibermatePaths.currentHome()) -> [HookIntegrationLocation] {
        func dir(_ path: String) -> URL { home.appendingPathComponent(path, isDirectory: true) }
        return [
            .init(displayName: "Claude Code", file: .userSettings(home: home), toolDirectory: dir(".claude")),
            .init(displayName: "OpenAI Codex CLI",
                  file: HookConfigFile(url: dir(".codex").appendingPathComponent("hooks.json"), schema: .codex),
                  toolDirectory: dir(".codex"),
                  note: "Codex asks you to review and trust new hooks in its /hooks menu before they run."),
            .init(displayName: "Gemini CLI",
                  file: HookConfigFile(url: dir(".gemini").appendingPathComponent("settings.json"), schema: .gemini),
                  toolDirectory: dir(".gemini")),
            .init(displayName: "Qwen Code",
                  file: HookConfigFile(url: dir(".qwen").appendingPathComponent("settings.json"), schema: .qwen),
                  toolDirectory: dir(".qwen")),
            .init(displayName: "GitHub Copilot CLI",
                  file: HookConfigFile(url: dir(".copilot/hooks").appendingPathComponent("hibermate.json"),
                                       schema: .copilot, ownedFile: true, createsParentDirectory: true),
                  toolDirectory: dir(".copilot")),
            .init(displayName: "Cursor (editor agent and CLI)",
                  file: HookConfigFile(url: dir(".cursor").appendingPathComponent("hooks.json"), schema: .cursor),
                  toolDirectory: dir(".cursor")),
        ]
    }

    public static func openCodePlugin(home: URL = HibermatePaths.currentHome()) -> URL {
        home.appendingPathComponent(".config/opencode/plugins/hibermate.js")
    }

    public static let openCodePluginHeader = "// Hibermate plugin for OpenCode"

    public struct RemovalReport: Sendable {
        public var removed: [String] = []
        public var failed: [(name: String, reason: String)] = []
    }

    /// Removes Hibermate's entries from every tool. Each edit is backed up and
    /// atomic. Files that are corrupt or contain no Hibermate entries are left untouched.
    public static func removeAll(home: URL = HibermatePaths.currentHome(), now: Date = Date()) -> RemovalReport {
        var report = RemovalReport()
        for location in hookFiles(home: home) {
            do {
                if try location.file.uninstall(now: now).changed { report.removed.append(location.displayName) }
            } catch {
                report.failed.append((location.displayName, String(describing: error)))
            }
        }
        let plugin = openCodePlugin(home: home)
        if let text = try? String(contentsOf: plugin, encoding: .utf8), text.hasPrefix(openCodePluginHeader) {
            if (try? FileManager.default.removeItem(at: plugin)) != nil {
                report.removed.append("OpenCode")
            } else {
                report.failed.append(("OpenCode", "could not delete \(plugin.path)"))
            }
        }
        return report
    }
}
