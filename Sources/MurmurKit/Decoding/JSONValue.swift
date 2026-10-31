import Foundation

/// An order-preserving JSON value. `JSONSerialization` loses key order, which matters when
/// presenting device payloads, so Murmur ships its own small parser.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double, raw: String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a, _), .number(b, _)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(b)
        case .number(let d, _): hasher.combine(d)
        case .string(let s): hasher.combine(s)
        case .array(let a): hasher.combine(a)
        case .object(let o): for (k, v) in o { hasher.combine(k); hasher.combine(v) }
        }
    }

    public static func number(_ d: Double) -> JSONValue {
        if d.rounded() == d, abs(d) < 1e15 { return .number(d, raw: String(Int64(d))) }
        return .number(d, raw: String(d))
    }

    public var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }

    public var numericValue: Double? {
        switch self {
        case .number(let d, _): d
        case .bool(let b): b ? 1 : 0
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var children: [(key: String, value: JSONValue)] {
        switch self {
        case .array(let a): a.enumerated().map { (String($0.offset), $0.element) }
        case .object(let o): o.map { ($0.0, $0.1) }
        default: []
        }
    }

    /// Resolves a path of keys / array indices.
    public func value(at path: [String]) -> JSONValue? {
        var current = self
        for component in path {
            switch current {
            case .object(let o):
                guard let v = o.first(where: { $0.0 == component })?.1 else { return nil }
                current = v
            case .array(let a):
                guard let i = Int(component), a.indices.contains(i) else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }

    // MARK: Serialization

    public func serialized(pretty: Bool = true, indent: String = "  ") -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, pretty: Bool, indent: String, level: Int) {
        let nl = pretty ? "\n" : ""
        let pad = pretty ? String(repeating: indent, count: level + 1) : ""
        let closePad = pretty ? String(repeating: indent, count: level) : ""
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(_, let raw): out += raw
        case .string(let s): out += JSONValue.quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, v) in a.enumerated() {
                out += pad
                v.write(into: &out, pretty: pretty, indent: indent, level: level + 1)
                if i < a.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (i, (k, v)) in o.enumerated() {
                out += pad + JSONValue.quote(k) + (pretty ? ": " : ":")
                v.write(into: &out, pretty: pretty, indent: indent, level: level + 1)
                if i < o.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "}"
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    public static func parse(_ data: Data) -> JSONValue? {
        var parser = JSONParser(bytes: [UInt8](data))
        return try? parser.parseDocument()
    }

    public static func parse(_ string: String) -> JSONValue? { parse(Data(string.utf8)) }

    /// Returns a description of the first syntax error, or nil if the text is valid JSON.
    public static func validationError(_ string: String) -> String? {
        var parser = JSONParser(bytes: Array(string.utf8))
        do {
            _ = try parser.parseDocument()
            return nil
        } catch let e as JSONParser.ParseError {
            return e.description
        } catch {
            return error.localizedDescription
        }
    }
}

struct JSONParser {
    struct ParseError: Error, CustomStringConvertible {
        let message: String
        let offset: Int
        var description: String { "\(message) at offset \(offset)" }
    }

    let bytes: [UInt8]
    var i = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip UTF-8 BOM
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWS()
        let v = try parseValue()
        skipWS()
        guard i == bytes.count else { throw ParseError(message: "Unexpected trailing characters", offset: i) }
        return v
    }

    mutating func skipWS() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        guard i < bytes.count else { throw ParseError(message: "Unexpected end of input", offset: i) }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw ParseError(message: "Unexpected character '\(Character(UnicodeScalar(bytes[i])))'", offset: i)
        }
    }

    mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else {
            throw ParseError(message: "Invalid literal", offset: i)
        }
        i += w.count
    }

    mutating func parseObject() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth < 512 else { throw ParseError(message: "Nesting too deep", offset: i) }
        i += 1
        var members: [(String, JSONValue)] = []
        skipWS()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipWS()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError(message: "Expected object key", offset: i) }
            let key = try parseString()
            skipWS()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError(message: "Expected ':'", offset: i) }
            i += 1
            skipWS()
            members.append((key, try parseValue()))
            skipWS()
            guard i < bytes.count else { throw ParseError(message: "Unterminated object", offset: i) }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            throw ParseError(message: "Expected ',' or '}'", offset: i)
        }
    }

    mutating func parseArray() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth < 512 else { throw ParseError(message: "Nesting too deep", offset: i) }
        i += 1
        var items: [JSONValue] = []
        skipWS()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWS()
            items.append(try parseValue())
            skipWS()
            guard i < bytes.count else { throw ParseError(message: "Unterminated array", offset: i) }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw ParseError(message: "Expected ',' or ']'", offset: i)
        }
    }

    mutating func parseString() throws -> String {
        i += 1
        var buf: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: buf, as: UTF8.self)
            }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let scalar = UnicodeScalar(code) ?? "\u{FFFD}"
                    buf.append(contentsOf: Array(String(scalar).utf8))
                default:
                    throw ParseError(message: "Invalid escape sequence", offset: i - 1)
                }
                continue
            }
            if c < 0x20 { throw ParseError(message: "Control character in string", offset: i) }
            buf.append(c)
            i += 1
        }
        throw ParseError(message: "Unterminated string", offset: i)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
            throw ParseError(message: "Invalid unicode escape", offset: i)
        }
        i += 4
        return v
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = i
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        func digits() -> Int {
            let s = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            return i - s
        }
        guard digits() > 0 else { throw ParseError(message: "Invalid number", offset: start) }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw ParseError(message: "Invalid number", offset: start) }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw ParseError(message: "Invalid number", offset: start) }
        }
        let raw = String(decoding: bytes[start..<i], as: UTF8.self)
        return .number(Double(raw) ?? 0, raw: raw)
    }
}
