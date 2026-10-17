import Foundation

/// How one tool's JSON hook configuration is laid out.
///
/// - grouped (Claude Code, Codex, Gemini, Qwen): `hooks.<Event>: [ { "hooks": [handler] } ]`
/// - flat (Cursor, Copilot): `hooks.<Event>: [handler]`
public struct HookConfigSchema: Sendable {
    public var agent: AgentID
    public var events: [String]
    public var grouped: Bool
    /// The handler key that holds the shell command ("command", or "bash" for Copilot).
    public var commandKey: String
    /// Top-level members added only when the file is created from scratch, e.g. `"version": 1`.
    public var newFileMembers: [JSONValue.Member]
    /// Builds the handler object for one event.
    public var handler: @Sendable (_ event: String, _ command: String) -> JSONValue
    /// Whether the command passes the event name as an argument (see AgentParsers).
    public var passesEventName: Bool
    /// JSON the shell wrapper prints on stdout for tools that expect a reply.
    /// nil means print nothing.
    public var reply: @Sendable (_ event: String) -> String?

    /// The marker that identifies Hibermate's entries in any tool's config.
    public static let marker = "/Application Support/Hibermate/hooks/hibermate-hook"

    /// The shell guard makes a leftover entry a silent no-op that exits 0
    /// after Hibermate is deleted. The hook binary itself never prints;
    /// a reply, if the tool needs one, comes from `printf` in the wrapper.
    public func command(for event: String) -> String {
        let args = passesEventName ? "\(agent.rawValue) \(event)" : agent.rawValue
        var cmd = #"f="$HOME/Library/Application Support/Hibermate/hooks/hibermate-hook"; [ -x "$f" ] && "$f" "# + args + " >/dev/null 2>&1;"
        if let reply = reply(event) { cmd += " printf '%s' '\(reply)';" }
        return cmd + " exit 0"
    }

    public func isOurs(_ handler: JSONValue) -> Bool {
        handler[commandKey]?.stringValue?.contains(Self.marker) == true
    }
}

extension HookConfigSchema {
    private static func standardHandler(timeout: JSONValue) -> @Sendable (String, String) -> JSONValue {
        { _, command in
            .object([.init("type", .string("command")), .init("command", .string(command)), .init("timeout", timeout)])
        }
    }

    public static let claudeCode = HookConfigSchema(
        agent: .claudeCode, events: ClaudeCodeParser.registeredEvents, grouped: true, commandKey: "command",
        newFileMembers: [], handler: standardHandler(timeout: .number("5")), passesEventName: false, reply: { _ in nil })

    public static let codex = HookConfigSchema(
        agent: .codex, events: CodexParser.registeredEvents, grouped: true, commandKey: "command",
        newFileMembers: [], handler: standardHandler(timeout: .number("5")), passesEventName: true, reply: { _ in nil })

    public static let gemini = HookConfigSchema(
        agent: .gemini, events: GeminiParser.registeredEvents, grouped: true, commandKey: "command",
        newFileMembers: [],
        handler: { _, command in
            .object([.init("name", .string("hibermate")), .init("type", .string("command")),
                     .init("command", .string(command)), .init("timeout", .number("5000"))]) // milliseconds
        },
        passesEventName: true, reply: { _ in nil })

    public static let qwen = HookConfigSchema(
        agent: .qwen, events: QwenParser.registeredEvents, grouped: true, commandKey: "command",
        newFileMembers: [], handler: standardHandler(timeout: .number("5")), passesEventName: true, reply: { _ in nil })

    public static let cursor = HookConfigSchema(
        agent: .cursor, events: CursorParser.registeredEvents, grouped: false, commandKey: "command",
        newFileMembers: [.init("version", .number("1"))],
        handler: { _, command in .object([.init("command", .string(command)), .init("timeout", .number("5"))]) },
        passesEventName: true, reply: { CursorParser.reply(for: $0) })

    public static let copilot = HookConfigSchema(
        agent: .copilot, events: CopilotParser.registeredEvents, grouped: false, commandKey: "bash",
        newFileMembers: [.init("version", .number("1"))],
        handler: { _, command in
            .object([.init("type", .string("command")), .init("bash", .string(command)), .init("timeoutSec", .number("5"))])
        },
        passesEventName: true, reply: { _ in nil })
}

/// Adds and removes Hibermate's hook entries in a tool's JSON config. Only
/// Hibermate's own handlers are touched. Everything else is kept in its
/// original order.
public enum HookConfigMerger {
    /// Parses an existing file. A missing file (nil) becomes `{}`. An empty
    /// or invalid file is corrupt, and Hibermate refuses to edit it.
    public static func parse(_ data: Data?) throws -> JSONValue {
        guard let data else { return .object([]) }
        let root: JSONValue
        do {
            root = try OrderedJSONParser.parse(data)
        } catch let e as JSONParseError {
            throw ClaudeSettingsError.corrupt("invalid JSON at byte \(e.offset): \(e.message)")
        }
        // Cross-check with Foundation's parser, so both must agree the file is valid.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw ClaudeSettingsError.corrupt("invalid JSON")
        }
        guard case .object = root else { throw ClaudeSettingsError.unexpectedShape("top level is not an object") }
        if let hooks = root["hooks"] {
            guard case .object(let events) = hooks else { throw ClaudeSettingsError.unexpectedShape("\"hooks\" is not an object") }
            for m in events {
                guard case .array = m.value else {
                    throw ClaudeSettingsError.unexpectedShape("\"hooks.\(m.key)\" is not an array")
                }
            }
        }
        return root
    }

    /// Returns `root` with exactly one Hibermate entry per event. Idempotent.
    public static func install(into root: JSONValue, schema: HookConfigSchema, isNewFile: Bool = false) throws -> JSONValue {
        guard case .object(var top) = removeOurs(from: root, schema: schema) else {
            throw ClaudeSettingsError.unexpectedShape("top level is not an object")
        }
        if isNewFile, top.isEmpty { top = schema.newFileMembers }
        var hooksIndex = top.firstIndex { $0.key == "hooks" }
        if hooksIndex == nil {
            top.append(.init("hooks", .object([])))
            hooksIndex = top.count - 1
        }
        guard case .object(var eventMembers) = top[hooksIndex!].value else {
            throw ClaudeSettingsError.unexpectedShape("\"hooks\" is not an object")
        }
        for event in schema.events {
            let handler = schema.handler(event, schema.command(for: event))
            // No "matcher" key: an omitted matcher matches everything.
            let entry: JSONValue = schema.grouped ? .object([.init("hooks", .array([handler]))]) : handler
            if let idx = eventMembers.firstIndex(where: { $0.key == event }) {
                guard case .array(var entries) = eventMembers[idx].value else {
                    throw ClaudeSettingsError.unexpectedShape("\"hooks.\(event)\" is not an array")
                }
                entries.append(entry)
                eventMembers[idx].value = .array(entries)
            } else {
                eventMembers.append(.init(event, .array([entry])))
            }
        }
        top[hooksIndex!].value = .object(eventMembers)
        return .object(top)
    }

    /// Removes only Hibermate's handlers. A container is dropped only if it
    /// became empty because of that removal. Shapes it doesn't recognize are
    /// left untouched.
    public static func removeOurs(from root: JSONValue, schema: HookConfigSchema) -> JSONValue {
        guard case .object(var top) = root,
              let hooksIndex = top.firstIndex(where: { $0.key == "hooks" }),
              case .object(let eventMembers) = top[hooksIndex].value else { return root }

        var newEvents: [JSONValue.Member] = []
        var removedAny = false
        for member in eventMembers {
            guard case .array(let entries) = member.value else { newEvents.append(member); continue }
            var kept: [JSONValue] = []
            var removedInEvent = false
            for entry in entries {
                if !schema.grouped {
                    if schema.isOurs(entry) { removedInEvent = true } else { kept.append(entry) }
                    continue
                }
                guard case .object(var groupMembers) = entry,
                      let hIdx = groupMembers.firstIndex(where: { $0.key == "hooks" }),
                      case .array(let handlers) = groupMembers[hIdx].value else {
                    kept.append(entry)
                    continue
                }
                let keptHandlers = handlers.filter { !schema.isOurs($0) }
                if keptHandlers.count == handlers.count { kept.append(entry); continue }
                removedInEvent = true
                if keptHandlers.isEmpty { continue }
                groupMembers[hIdx].value = .array(keptHandlers)
                kept.append(.object(groupMembers))
            }
            removedAny = removedAny || removedInEvent
            if removedInEvent, kept.isEmpty { continue }
            newEvents.append(.init(member.key, .array(kept)))
        }
        if removedAny, newEvents.isEmpty {
            top.remove(at: hooksIndex)
        } else {
            top[hooksIndex].value = .object(newEvents)
        }
        return .object(top)
    }

    public static func containsOurs(_ root: JSONValue, schema: HookConfigSchema) -> Bool {
        removeOurs(from: root, schema: schema) != root
    }
}
