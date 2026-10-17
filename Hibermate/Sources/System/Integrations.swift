import Foundation
import HibermateCore

/// One way of detecting AI work. Each integration is opt-in, and onboarding
/// asks for consent to each one separately. See docs/AGENTS.md.
protocol AgentIntegration: AnyObject {
    var id: AgentID { get }
    var displayName: String { get }
    /// Plain-language description of exactly what enabling it changes.
    var changeSummary: String { get }
    /// Whether the tool appears to be installed on this Mac.
    var isToolPresent: Bool { get }
    func isEnabled() -> Bool
    func enable() throws
    func disable() throws
}

/// Copies the hook binary out of the app bundle into
/// `~/Library/Application Support/Hibermate/hooks/`. Hook entries point there,
/// not into the app, so a moved or deleted app leaves only a silent no-op.
enum HookBinaryInstaller {
    static func install(paths: HibermatePaths) throws {
        guard let source = Bundle.main.url(forAuxiliaryExecutable: "hibermate-hook") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.hooksDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(try Data(contentsOf: source), to: paths.hookBinary, permissions: 0o755)
    }

    static func remove(paths: HibermatePaths) {
        try? FileManager.default.removeItem(at: paths.hooksDirectory)
    }
}

/// Tools configured through a JSON hooks file (Claude Code, Codex, Gemini CLI,
/// Qwen Code, Copilot CLI, Cursor).
final class HookFileIntegration: AgentIntegration {
    let id: AgentID
    let displayName: String
    let changeSummary: String
    private let file: HookConfigFile
    private let toolDirectory: URL
    private let paths: HibermatePaths
    private let dryRun: Bool

    init(displayName: String, file: HookConfigFile, toolDirectory: URL, extraNote: String? = nil,
         paths: HibermatePaths, dryRun: Bool) {
        self.id = file.schema.agent
        self.displayName = displayName
        self.file = file
        self.toolDirectory = toolDirectory
        self.paths = paths
        self.dryRun = dryRun
        let path = file.url.path.replacingOccurrences(of: HibermatePaths.currentHome().path, with: "~")
        var summary = file.ownedFile
            ? "Adds the file \(path) with Hibermate's hooks."
            : "Adds Hibermate hook entries to \(path) (after making a backup). Your existing settings and other hooks are kept."
        summary += " The hooks only record when a session starts and stops working; they never read your prompts, code, or transcripts."
        if let extraNote { summary += " " + extraNote }
        self.changeSummary = summary
    }

    var isToolPresent: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: toolDirectory.path, isDirectory: &isDir) && isDir.boolValue
    }

    func isEnabled() -> Bool { (try? file.isInstalled()) ?? false }

    func enable() throws {
        guard !dryRun else {
            appLog.notice("[dry-run] would install hook binary and add hooks to \(self.file.url.path, privacy: .public)")
            return
        }
        try HookBinaryInstaller.install(paths: paths)
        try file.install()
    }

    func disable() throws {
        guard !dryRun else {
            appLog.notice("[dry-run] would remove Hibermate hooks from \(self.file.url.path, privacy: .public)")
            return
        }
        try file.uninstall()
    }
}

/// OpenCode has no hook config, only JS plugins. Hibermate installs a small
/// plugin that forwards session status to the hook binary.
final class OpenCodeIntegration: AgentIntegration {
    let id = AgentID.opencode
    let displayName = "OpenCode"
    let changeSummary = """
        Adds a small plugin at ~/.config/opencode/plugins/hibermate.js that tells Hibermate when an OpenCode \
        session is busy or idle. It sends only the session ID and status, never prompts or code.
        """
    static let header = "// Hibermate plugin for OpenCode"

    private let home: URL
    private let paths: HibermatePaths
    private let dryRun: Bool

    init(home: URL = HibermatePaths.currentHome(), paths: HibermatePaths, dryRun: Bool) {
        self.home = home
        self.paths = paths
        self.dryRun = dryRun
    }

    private var configDir: URL { home.appendingPathComponent(".config/opencode", isDirectory: true) }
    private var pluginFile: URL { configDir.appendingPathComponent("plugins/hibermate.js") }

    var isToolPresent: Bool { FileManager.default.fileExists(atPath: configDir.path) }

    func isEnabled() -> Bool {
        (try? String(contentsOf: pluginFile, encoding: .utf8))?.hasPrefix(Self.header) ?? false
    }

    func enable() throws {
        guard !dryRun else {
            appLog.notice("[dry-run] would install \(self.pluginFile.path, privacy: .public)")
            return
        }
        try HookBinaryInstaller.install(paths: paths)
        try FileManager.default.createDirectory(at: pluginFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data(Self.plugin.utf8), to: pluginFile, permissions: 0o644)
    }

    func disable() throws {
        guard !dryRun else { return }
        // Delete only a file Hibermate wrote.
        if isEnabled() { try FileManager.default.removeItem(at: pluginFile) }
    }

    static let plugin = """
        \(header) (installed by Hibermate; safe to delete).
        // Tells Hibermate when an OpenCode session is busy or idle, so the Mac stays
        // awake while it works. Sends only the session ID, status, and folder.
        // It never throws, never waits, and does nothing if Hibermate is gone.
        import { spawn } from "node:child_process";
        import { existsSync } from "node:fs";
        import { homedir } from "node:os";

        const HOOK = `${homedir()}/Library/Application Support/Hibermate/hooks/hibermate-hook`;
        const FORWARD = new Set([
          "session.status", "session.idle", "session.error", "session.deleted",
          "permission.asked", "permission.updated", "permission.replied", "question.asked",
          "message.part.updated",
        ]);
        const lastHeartbeat = new Map();

        function send(type, payload) {
          try {
            if (!existsSync(HOOK)) return;
            if (type === "message.part.updated") {
              const now = Date.now();
              if (now - (lastHeartbeat.get(payload.session_id) ?? 0) < 15000) return;
              lastHeartbeat.set(payload.session_id, now);
            }
            const child = spawn(HOOK, ["opencode", type], { stdio: ["pipe", "ignore", "ignore"], detached: true });
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify(payload));
            child.unref();
          } catch {}
        }

        export const HibermatePlugin = async ({ directory }) => ({
          event: async ({ event }) => {
            try {
              if (!event || !FORWARD.has(event.type)) return;
              const p = event.properties ?? {};
              const sessionID = p.sessionID ?? p.info?.id ?? p.part?.sessionID;
              if (typeof sessionID !== "string") return;
              send(event.type, { session_id: sessionID, status: p.status?.type, cwd: directory });
            } catch {}
          },
        });

        """
}

enum IntegrationCatalog {
    static func all(paths: HibermatePaths, dryRun: Bool) -> [AgentIntegration] {
        let home = HibermatePaths.currentHome()
        func dir(_ path: String) -> URL { home.appendingPathComponent(path, isDirectory: true) }
        return [
            HookFileIntegration(displayName: "Claude Code", file: .userSettings(home: home), toolDirectory: dir(".claude"),
                                paths: paths, dryRun: dryRun),
            HookFileIntegration(displayName: "OpenAI Codex CLI",
                                file: HookConfigFile(url: dir(".codex").appendingPathComponent("hooks.json"), schema: .codex),
                                toolDirectory: dir(".codex"),
                                extraNote: "Codex asks you to review and trust new hooks in its /hooks menu before they run.",
                                paths: paths, dryRun: dryRun),
            HookFileIntegration(displayName: "Gemini CLI",
                                file: HookConfigFile(url: dir(".gemini").appendingPathComponent("settings.json"), schema: .gemini),
                                toolDirectory: dir(".gemini"), paths: paths, dryRun: dryRun),
            HookFileIntegration(displayName: "Qwen Code",
                                file: HookConfigFile(url: dir(".qwen").appendingPathComponent("settings.json"), schema: .qwen),
                                toolDirectory: dir(".qwen"), paths: paths, dryRun: dryRun),
            HookFileIntegration(displayName: "GitHub Copilot CLI",
                                file: HookConfigFile(url: dir(".copilot/hooks").appendingPathComponent("hibermate.json"),
                                                     schema: .copilot, ownedFile: true, createsParentDirectory: true),
                                toolDirectory: dir(".copilot"), paths: paths, dryRun: dryRun),
            HookFileIntegration(displayName: "Cursor (editor agent and CLI)",
                                file: HookConfigFile(url: dir(".cursor").appendingPathComponent("hooks.json"), schema: .cursor),
                                toolDirectory: dir(".cursor"), paths: paths, dryRun: dryRun),
            OpenCodeIntegration(home: home, paths: paths, dryRun: dryRun),
        ]
    }
}
