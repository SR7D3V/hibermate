import Foundation
import Testing
@testable import HibermateCore

func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hibermate-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A typical settings.json in the 2-space format that Claude Code writes, with another tool's hook.
let sampleSettings = """
{
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(npm test)"
    ]
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/other-tool notify"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/bin/guard.sh"
          }
        ]
      }
    ]
  },
  "cleanupPeriodDays": 30,
  "ratio": 1.50,
  "unicode": "héllo ✓ \\u0001 \\"q\\" /path"
}

"""

@Suite("Order-preserving JSON")
struct OrderedJSONTests {
    @Test func roundTripsClaudeStyleByteForByte() throws {
        let data = Data(sampleSettings.utf8)
        let value = try OrderedJSONParser.parse(data)
        #expect(OrderedJSONWriter.matchingStyle(of: data).serialize(value) == data)
    }

    @Test func preservesKeyOrderAndNumberText() throws {
        let value = try OrderedJSONParser.parse(Data(#"{"z":1,"a":1.50,"m":-0.0e10}"#.utf8))
        guard case .object(let members) = value else { Issue.record("not object"); return }
        #expect(members.map(\.key) == ["z", "a", "m"])
        #expect(members[1].value == .number("1.50"))
    }

    @Test func detectsFourSpaceIndentAndNoTrailingNewline() throws {
        let data = Data("{\n    \"a\": [\n        1\n    ]\n}".utf8)
        let w = OrderedJSONWriter.matchingStyle(of: data)
        #expect(w.indent == "    ")
        #expect(!w.trailingNewline)
        #expect(w.serialize(try OrderedJSONParser.parse(data)) == data)
    }

    @Test(arguments: ["", "{", "{\"a\":}", "{\"a\":1,}", "[1,]", "// c\n{}", "{\"a\":NaN}", "{'a':1}",
                      "{\"a\":1} x", "\"\\ud800\"", "{\"a\":01}"])
    func rejectsInvalid(text: String) {
        #expect(throws: JSONParseError.self) { try OrderedJSONParser.parse(Data(text.utf8)) }
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let v = try OrderedJSONParser.parse(Data(#""a\n\u00e9\ud83d\ude00""#.utf8))
        #expect(v == .string("a\né😀"))
    }
}

@Suite("Claude settings merge / unmerge")
struct ClaudeSettingsMergerTests {
    func hibermateHandlers(_ root: JSONValue) -> Int {
        guard case .object(let events)? = root["hooks"] else { return 0 }
        var n = 0
        for e in events {
            guard case .array(let groups) = e.value else { continue }
            for g in groups {
                guard case .array(let hs)? = g["hooks"] else { continue }
                n += hs.filter(ClaudeSettingsMerger.isOurs).count
            }
        }
        return n
    }

    @Test func installPreservesEverythingAndAddsOnePerEvent() throws {
        let root = try ClaudeSettingsMerger.parse(Data(sampleSettings.utf8))
        let installed = try ClaudeSettingsMerger.install(into: root)
        #expect(hibermateHandlers(installed) == ClaudeCodeParser.registeredEvents.count)
        // Other tools' hooks are still there, in order.
        let text = String(decoding: OrderedJSONWriter().serialize(installed), as: UTF8.self)
        #expect(text.contains("/usr/local/bin/other-tool notify"))
        #expect(text.contains("~/bin/guard.sh"))
        guard case .object(let top) = installed else { return }
        #expect(top.map(\.key) == ["model", "permissions", "hooks", "cleanupPeriodDays", "ratio", "unicode"])
    }

    @Test func installIsIdempotent() throws {
        let root = try ClaudeSettingsMerger.parse(Data(sampleSettings.utf8))
        let once = try ClaudeSettingsMerger.install(into: root)
        #expect(try ClaudeSettingsMerger.install(into: once) == once)
    }

    @Test func uninstallRestoresOriginalExactly() throws {
        let data = Data(sampleSettings.utf8)
        let root = try ClaudeSettingsMerger.parse(data)
        let removed = ClaudeSettingsMerger.removeOurs(from: try ClaudeSettingsMerger.install(into: root))
        #expect(removed == root)
        #expect(OrderedJSONWriter.matchingStyle(of: data).serialize(removed) == data)
    }

    @Test func uninstallFromFileWithoutHooksRemovesHooksKey() throws {
        let root = try ClaudeSettingsMerger.parse(Data(#"{"model":"opus"}"#.utf8))
        let round = ClaudeSettingsMerger.removeOurs(from: try ClaudeSettingsMerger.install(into: root))
        #expect(round == root)
    }

    @Test func userEmptyContainersAreKeptWhenWeNeverTouchedThem() throws {
        let root = try ClaudeSettingsMerger.parse(Data(#"{"hooks":{"Stop":[]},"x":1}"#.utf8))
        #expect(ClaudeSettingsMerger.removeOurs(from: root) == root)
        // Known limitation: an empty array for an event we register can't be
        // told apart from one we created, so uninstall drops it. Both mean
        // "no hooks"; the backup keeps the original bytes.
        let round = ClaudeSettingsMerger.removeOurs(from: try ClaudeSettingsMerger.install(into: root))
        #expect(round == (try ClaudeSettingsMerger.parse(Data(#"{"x":1}"#.utf8))))
    }

    @Test func removesOnlyOurHandlerFromSharedGroup() throws {
        let cmd = ClaudeSettingsMerger.hookCommand.replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine.sh"},{"type":"command","command":"\#(cmd)"}]}]}}"#
        let root = try ClaudeSettingsMerger.parse(Data(json.utf8))
        let removed = ClaudeSettingsMerger.removeOurs(from: root)
        #expect(hibermateHandlers(removed) == 0)
        #expect(String(decoding: OrderedJSONWriter().serialize(removed), as: UTF8.self).contains("mine.sh"))
    }

    @Test func missingFileIsEmptyObject() throws {
        #expect(try ClaudeSettingsMerger.parse(nil) == .object([]))
    }

    @Test(arguments: ["", "not json", "{\"hooks\": [", "[1,2]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}"])
    func corruptOrUnexpectedIsRefused(text: String) {
        #expect(throws: ClaudeSettingsError.self) { try ClaudeSettingsMerger.parse(Data(text.utf8)) }
    }

    @Test func hookCommandIsGuardedAndSilent() {
        let c = ClaudeSettingsMerger.hookCommand
        #expect(c.contains("[ -x \"$f\" ]"))
        #expect(c.contains(">/dev/null 2>&1"))
        #expect(c.hasSuffix("exit 0"))
        #expect(c.contains(ClaudeSettingsMerger.marker))
    }
}

@Suite("Claude settings file editing")
struct ClaudeSettingsFileTests {
    @Test func installBacksUpAndWritesAtomically() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("settings.json")
        try Data(sampleSettings.utf8).write(to: url)
        chmod(url.path, 0o644)
        let file = ClaudeSettingsFile(url: url)

        let outcome = try file.install()
        #expect(outcome.changed)
        let backup = try #require(outcome.backup)
        #expect(try Data(contentsOf: backup) == Data(sampleSettings.utf8))
        #expect(try file.isInstalled())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o644, "permissions preserved")
        #expect(try file.install().changed == false, "second install is a no-op")

        try file.uninstall()
        #expect(try Data(contentsOf: url) == Data(sampleSettings.utf8), "uninstall restores byte for byte")
    }

    @Test func corruptFileIsRefusedAndUntouched() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("settings.json")
        let corrupt = Data("{ \"model\": \"opus\", ".utf8)
        try corrupt.write(to: url)
        #expect(throws: ClaudeSettingsError.self) { try ClaudeSettingsFile(url: url).install() }
        #expect(try Data(contentsOf: url) == corrupt)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["settings.json"], "no backup or temp files left behind")
    }

    @Test func missingFileIsCreatedWhenClaudeDirExists() throws {
        let dir = makeTempDir()
        let file = ClaudeSettingsFile(url: dir.appendingPathComponent("settings.json"))
        #expect(try file.install().changed)
        #expect(try file.isInstalled())
        try file.uninstall()
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "{}\n")
    }

    @Test func missingClaudeDirIsAnError() {
        let file = ClaudeSettingsFile(url: makeTempDir().appendingPathComponent("nope/settings.json"))
        #expect(throws: ClaudeSettingsError.claudeDirectoryMissing) { try file.install() }
        #expect(throws: Never.self) { try file.uninstall() }
    }

    @Test func symlinkedSettingsAreEditedThroughTheLink() throws {
        let dir = makeTempDir()
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: real)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try ClaudeSettingsFile(url: link).install()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "link kept")
        #expect(try ClaudeSettingsFile(url: real).isInstalled())
    }
}

@Suite("Compact JSON style")
struct CompactJSONTests {
    @Test(arguments: [#"{"a":1,"b":[1,{"c":"d"}],"e":{}}"#, #"{"a":[]}"# + "\n", "{}"])
    func compactFilesRoundTrip(text: String) throws {
        let data = Data(text.utf8)
        #expect(OrderedJSONWriter.matchingStyle(of: data).serialize(try OrderedJSONParser.parse(data)) == data)
    }
}
