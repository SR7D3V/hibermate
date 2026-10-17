import Foundation

public enum ClaudeSettingsError: Error, Equatable {
    /// The existing file isn't valid JSON. Hibermate refuses to edit it.
    case corrupt(String)
    /// The top level, or `hooks`, isn't a JSON object.
    case unexpectedShape(String)
    /// The `~/.claude` directory doesn't exist (Claude Code not installed or never run).
    case claudeDirectoryMissing
    /// The file changed while being edited; nothing was written.
    case concurrentModification
    case io(String)
}

/// Adds and removes Hibermate's hook entries in Claude Code's settings.json.
///
/// Hibermate's entries are recognized only by their command string, which
/// contains `marker`. The docs don't document custom keys on hook handlers,
/// so none are added. Everything else in the file, including other tools'
/// hooks, is preserved in its original order.
public enum ClaudeSettingsMerger {
    public static let marker = "/Application Support/Hibermate/hooks/hibermate-hook"

    /// The shell guard means a leftover entry still exits 0 silently if
    /// Hibermate has been deleted (invariant 4).
    public static let hookCommand =
        #"f="$HOME/Library/Application Support/Hibermate/hooks/hibermate-hook"; [ -x "$f" ] && "$f" >/dev/null 2>&1; exit 0"#

    public static let hookTimeoutSeconds = 5

    public static func handlerEntry() -> JSONValue {
        .object([
            .init("type", .string("command")),
            .init("command", .string(hookCommand)),
            .init("timeout", .number(String(hookTimeoutSeconds))),
        ])
    }

    public static func isOurs(_ handler: JSONValue) -> Bool {
        handler["command"]?.stringValue?.contains(marker) == true
    }

    /// Parses an existing file. A missing file (nil) is treated as `{}`. An
    /// empty or invalid file is corrupt.
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
    public static func install(into root: JSONValue, events: [String] = HookEventMapping.registeredEvents) throws -> JSONValue {
        guard case .object(var top) = removeOurs(from: root) else {
            throw ClaudeSettingsError.unexpectedShape("top level is not an object")
        }
        var hooksIndex = top.firstIndex { $0.key == "hooks" }
        if hooksIndex == nil {
            top.append(.init("hooks", .object([])))
            hooksIndex = top.count - 1
        }
        guard case .object(var eventMembers) = top[hooksIndex!].value else {
            throw ClaudeSettingsError.unexpectedShape("\"hooks\" is not an object")
        }
        // No "matcher" key: an omitted matcher matches everything, for every event.
        let group = JSONValue.object([.init("hooks", .array([handlerEntry()]))])
        for event in events {
            if let idx = eventMembers.firstIndex(where: { $0.key == event }) {
                guard case .array(var groups) = eventMembers[idx].value else {
                    throw ClaudeSettingsError.unexpectedShape("\"hooks.\(event)\" is not an array")
                }
                groups.append(group)
                eventMembers[idx].value = .array(groups)
            } else {
                eventMembers.append(.init(event, .array([group])))
            }
        }
        top[hooksIndex!].value = .object(eventMembers)
        return .object(top)
    }

    /// Removes only Hibermate's handlers. A container is dropped only if it
    /// became empty because of that removal, so containers the user had
    /// (even empty ones) stay. Shapes it doesn't recognize are left untouched.
    public static func removeOurs(from root: JSONValue) -> JSONValue {
        guard case .object(var top) = root,
              let hooksIndex = top.firstIndex(where: { $0.key == "hooks" }),
              case .object(let eventMembers) = top[hooksIndex].value else { return root }

        var newEvents: [JSONValue.Member] = []
        var removedAny = false
        for member in eventMembers {
            guard case .array(let groups) = member.value else { newEvents.append(member); continue }
            var newGroups: [JSONValue] = []
            var removedInEvent = false
            for group in groups {
                guard case .object(var groupMembers) = group,
                      let hIdx = groupMembers.firstIndex(where: { $0.key == "hooks" }),
                      case .array(let handlers) = groupMembers[hIdx].value else {
                    newGroups.append(group)
                    continue
                }
                let kept = handlers.filter { !isOurs($0) }
                if kept.count == handlers.count { newGroups.append(group); continue }
                removedInEvent = true
                if kept.isEmpty { continue }
                groupMembers[hIdx].value = .array(kept)
                newGroups.append(.object(groupMembers))
            }
            removedAny = removedAny || removedInEvent
            if removedInEvent, newGroups.isEmpty { continue }
            newEvents.append(.init(member.key, .array(newGroups)))
        }
        if removedAny, newEvents.isEmpty {
            top.remove(at: hooksIndex)
        } else {
            top[hooksIndex].value = .object(newEvents)
        }
        return .object(top)
    }

    public static func containsOurs(_ root: JSONValue) -> Bool {
        removeOurs(from: root) != root
    }
}
