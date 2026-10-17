import Foundation

/// A JSON value that preserves object key order and keeps each number exactly
/// as written. `JSONSerialization` would reorder keys and reformat numbers,
/// which would rewrite the user's whole `~/.claude/settings.json` just to add a
/// few hook entries.
public indirect enum JSONValue: Equatable, Sendable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The number's original text, e.g. "1.50" or "1e3".
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

public struct JSONParseError: Error, Equatable {
    public var offset: Int
    public var message: String
}

/// Strict RFC 8259 parser: no comments, no trailing commas, no NaN.
public struct OrderedJSONParser {
    private let bytes: [UInt8]
    private var i = 0
    private var depth = 0
    private static let maxDepth = 256

    public static func parse(_ data: Data) throws -> JSONValue {
        var p = OrderedJSONParser(bytes: Array(data))
        // Skip a UTF-8 byte order mark.
        if p.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        p.skipWhitespace()
        let value = try p.parseValue()
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw p.error("unexpected trailing content") }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(offset: i, message: message)
    }

    private mutating func skipWhitespace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        let lit = Array(literal.utf8)
        guard i + lit.count <= bytes.count, Array(bytes[i..<(i + lit.count)]) == lit else {
            throw error("expected \(literal)")
        }
        i += lit.count
    }

    private mutating func parseValue() throws -> JSONValue {
        guard i < bytes.count else { throw error("unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("unexpected character")
        }
    }

    private mutating func nest() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw error("nesting too deep") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try nest()
        defer { depth -= 1 }
        i += 1
        var members: [JSONValue.Member] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
            i += 1
            skipWhitespace()
            members.append(.init(key, try parseValue()))
            skipWhitespace()
            guard i < bytes.count else { throw error("unterminated object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try nest()
        defer { depth -= 1 }
        i += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw error("unterminated array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func parseHex4() throws -> UInt16 {
        guard i + 4 <= bytes.count else { throw error("short \\u escape") }
        var v: UInt16 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
            default: throw error("bad hex digit")
            }
            v = v << 4 | UInt16(d)
            i += 1
        }
        return v
    }

    private mutating func parseString() throws -> String {
        i += 1 // opening quote
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw error("control character in string") }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < bytes.count else { throw error("unterminated escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalarValue = UInt32(try parseHex4())
                if (0xD800...0xDBFF).contains(scalarValue) {
                    guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                        throw error("lone high surrogate")
                    }
                    i += 2
                    let low = UInt32(try parseHex4())
                    guard (0xDC00...0xDFFF).contains(low) else { throw error("bad low surrogate") }
                    scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(scalarValue) {
                    throw error("lone low surrogate")
                }
                guard let scalar = Unicode.Scalar(scalarValue) else { throw error("bad code point") }
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw error("bad escape")
            }
        }
        guard let s = String(bytes: out, encoding: .utf8) else { throw error("invalid UTF-8") }
        return s
    }

    private mutating func parseNumber() throws -> String {
        let start = i
        func digits() -> Int {
            let s = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            return i - s
        }
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { throw error("bad number") }
        if bytes[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { throw error("bad number") }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw error("bad fraction") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw error("bad exponent") }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }
}

/// Serializes the way `JSON.stringify(value, null, indent)` does, which is how
/// Claude Code writes settings.json. A file Claude Code wrote round-trips byte for byte.
public struct OrderedJSONWriter {
    public var indent: String = "  "
    public var trailingNewline = true

    public init(indent: String = "  ", trailingNewline: Bool = true) {
        self.indent = indent
        self.trailingNewline = trailingNewline
    }

    /// Picks the indent and trailing-newline style of an existing file.
    public static func matchingStyle(of data: Data) -> OrderedJSONWriter {
        let text = String(decoding: data, as: UTF8.self)
        var writer = OrderedJSONWriter()
        writer.trailingNewline = text.hasSuffix("\n") || data.isEmpty
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            if !lead.isEmpty {
                writer.indent = lead.first == "\t" ? "\t" : String(repeating: " ", count: lead.count)
                break
            }
        }
        return writer
    }

    public func serialize(_ value: JSONValue) -> Data {
        var out = ""
        write(value, level: 0, into: &out)
        if trailingNewline { out += "\n" }
        return Data(out.utf8)
    }

    private func write(_ value: JSONValue, level: Int, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (idx, item) in items.enumerated() {
                out += String(repeating: indent, count: level + 1)
                write(item, level: level + 1, into: &out)
                out += idx < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: indent, count: level) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (idx, m) in members.enumerated() {
                out += String(repeating: indent, count: level + 1)
                Self.writeString(m.key, into: &out)
                out += ": "
                write(m.value, level: level + 1, into: &out)
                out += idx < members.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: indent, count: level) + "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
