import Foundation
import HibermateCore

/// One way of detecting AI work. Each integration is opt-in, and onboarding
/// asks for consent to each one separately.
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

final class ClaudeCodeIntegration: AgentIntegration {
    let id = AgentID.claudeCode
    let displayName = "Claude Code"
    let changeSummary = """
        Adds Hibermate hook entries to ~/.claude/settings.json (after making a backup). \
        Your existing settings and other hooks are kept. The hooks only record when a session starts and \
        stops working; they never read your prompts, code, or transcripts.
        """

    private let file: ClaudeSettingsFile
    private let paths: HibermatePaths
    private let dryRun: Bool

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, paths: HibermatePaths, dryRun: Bool) {
        self.file = .userSettings(home: home)
        self.paths = paths
        self.dryRun = dryRun
    }

    var isToolPresent: Bool {
        FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path)
    }

    func isEnabled() -> Bool {
        (try? file.isInstalled()) ?? false
    }

    func enable() throws {
        guard !dryRun else {
            appLog.notice("[dry-run] would install hook binary and merge hooks into \(self.file.url.path, privacy: .public)")
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
