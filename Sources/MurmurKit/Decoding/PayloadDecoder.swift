import Foundation

/// How to interpret a payload's bytes.
public enum PayloadFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case string
    case json
    case hex
    case base64
    case sparkplugB
    case int8, uint8
    case int16BE, int16LE, uint16BE, uint16LE
    case int32BE, int32LE, uint32BE, uint32LE
    case int64BE, int64LE, uint64BE, uint64LE
    case float32BE, float32LE, float64BE, float64LE

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .string: "String (UTF-8)"
        case .json: "JSON"
        case .hex: "Hex"
        case .base64: "Base64"
        case .sparkplugB: "Sparkplug B"
        case .int8: "Int8"
        case .uint8: "UInt8"
        case .int16BE: "Int16 BE"
        case .int16LE: "Int16 LE"
        case .uint16BE: "UInt16 BE"
        case .uint16LE: "UInt16 LE"
        case .int32BE: "Int32 BE"
        case .int32LE: "Int32 LE"
        case .uint32BE: "UInt32 BE"
        case .uint32LE: "UInt32 LE"
        case .int64BE: "Int64 BE"
        case .int64LE: "Int64 LE"
        case .uint64BE: "UInt64 BE"
        case .uint64LE: "UInt64 LE"
        case .float32BE: "Float32 BE"
        case .float32LE: "Float32 LE"
        case .float64BE: "Float64 BE"
        case .float64LE: "Float64 LE"
        }
    }

    public static let textual: [PayloadFormat] = [.auto, .string, .json, .hex, .base64, .sparkplugB]
    public static let binaryNumbers: [PayloadFormat] = [
        .int8, .uint8, .int16BE, .int16LE, .uint16BE, .uint16LE, .int32BE, .int32LE, .uint32BE, .uint32LE,
        .int64BE, .int64LE, .uint64BE, .uint64LE, .float32BE, .float32LE, .float64BE, .float64LE,
    ]

    var byteWidth: Int? {
        switch self {
        case .int8, .uint8: 1
        case .int16BE, .int16LE, .uint16BE, .uint16LE: 2
        case .int32BE, .int32LE, .uint32BE, .uint32LE, .float32BE, .float32LE: 4
        case .int64BE, .int64LE, .uint64BE, .uint64LE, .float64BE, .float64LE: 8
        default: nil
        }
    }
}

/// Result of decoding a payload.
public struct DecodedPayload: Sendable {
    public enum Kind: Sendable { case empty, text, json, binary, sparkplug, numbers }

    public let kind: Kind
    /// Text suitable for display / diffing.
    public let text: String
    /// Structured representation (JSON or Sparkplug), if any.
    public let json: JSONValue?
    /// The resolved format (e.g. `.auto` resolves to `.json`).
    public let format: PayloadFormat
    public let error: String?

    /// A single numeric value if the payload represents one (for charting).
    public var numericValue: Double? {
        if let json, !json.isContainer { return json.numericValue }
        if kind == .text { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if kind == .numbers, let json, case .array(let a) = json, a.count == 1 { return a[0].numericValue }
        return nil
    }
}

public enum PayloadDecoder {
    /// Topics that are conventionally Sparkplug B encoded.
    public static func isSparkplugTopic(_ topic: String) -> Bool {
        topic.hasPrefix("spBv1.0/") && !topic.contains("/STATE/")
    }

    public static func decode(_ data: Data, format: PayloadFormat, topic: String = "") -> DecodedPayload {
        if data.isEmpty { return DecodedPayload(kind: .empty, text: "", json: nil, format: format, error: nil) }
        switch format {
        case .auto:
            if isSparkplugTopic(topic), let sp = try? SparkplugDecoder.decode(data) {
                return DecodedPayload(kind: .sparkplug, text: sp.serialized(), json: sp, format: .sparkplugB, error: nil)
            }
            if let s = String(data: data, encoding: .utf8), isMostlyPrintable(s) {
                if let first = s.first(where: { !$0.isWhitespace }), "{[\"".contains(first) || s.count < 64,
                   let json = JSONValue.parse(data) {
                    // Only treat as JSON when it's structured, a quoted string, or a bare literal.
                    return DecodedPayload(kind: .json, text: json.isContainer ? json.serialized() : s, json: json, format: .json, error: nil)
                }
                return DecodedPayload(kind: .text, text: s, json: nil, format: .string, error: nil)
            }
            return DecodedPayload(kind: .binary, text: hexDump(data), json: nil, format: .hex, error: nil)
        case .string:
            let s = String(decoding: data, as: UTF8.self)
            return DecodedPayload(kind: .text, text: s, json: nil, format: .string, error: nil)
        case .json:
            if let json = JSONValue.parse(data) {
                return DecodedPayload(kind: .json, text: json.serialized(), json: json, format: .json, error: nil)
            }
            let s = String(decoding: data, as: UTF8.self)
            return DecodedPayload(kind: .text, text: s, json: nil, format: .json,
                                  error: JSONValue.validationError(s) ?? "Not valid JSON")
        case .hex:
            return DecodedPayload(kind: .binary, text: hexDump(data), json: nil, format: .hex, error: nil)
        case .base64:
            // Show the payload as base64, or decode it if it *is* base64 text.
            if let s = String(data: data, encoding: .utf8),
               let decoded = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
               !decoded.isEmpty {
                let inner = decode(decoded, format: .auto, topic: topic)
                return DecodedPayload(kind: inner.kind, text: inner.text, json: inner.json, format: .base64, error: nil)
            }
            return DecodedPayload(kind: .text, text: data.base64EncodedString(), json: nil, format: .base64, error: nil)
        case .sparkplugB:
            do {
                let sp = try SparkplugDecoder.decode(data)
                return DecodedPayload(kind: .sparkplug, text: sp.serialized(), json: sp, format: .sparkplugB, error: nil)
            } catch {
                return DecodedPayload(kind: .binary, text: hexDump(data), json: nil, format: .sparkplugB,
                                      error: "Not a valid Sparkplug B payload: \(error.localizedDescription)")
            }
        default:
            return decodeNumbers(data, format: format)
        }
    }

    static func decodeNumbers(_ data: Data, format: PayloadFormat) -> DecodedPayload {
        guard let width = format.byteWidth else { fatalError("not a numeric format") }
        let bytes = [UInt8](data)
        var values: [JSONValue] = []
        var offset = 0
        while offset + width <= bytes.count {
            let slice = Array(bytes[offset..<(offset + width)])
            let isLE: Bool = {
                switch format {
                case .int16LE, .uint16LE, .int32LE, .uint32LE, .int64LE, .uint64LE, .float32LE, .float64LE: true
                default: false
                }
            }()
            let ordered = isLE ? slice.reversed() : slice
            var raw: UInt64 = 0
            for b in ordered { raw = raw << 8 | UInt64(b) }
            let value: JSONValue
            switch format {
            case .int8: value = .number(Double(Int8(bitPattern: UInt8(raw))))
            case .uint8: value = .number(Double(raw))
            case .int16BE, .int16LE: value = .number(Double(Int16(bitPattern: UInt16(raw))))
            case .uint16BE, .uint16LE: value = .number(Double(raw))
            case .int32BE, .int32LE: value = .number(Double(Int32(bitPattern: UInt32(raw))))
            case .uint32BE, .uint32LE: value = .number(Double(raw))
            case .int64BE, .int64LE:
                let v = Int64(bitPattern: raw)
                value = .number(Double(v), raw: String(v))
            case .uint64BE, .uint64LE: value = .number(Double(raw), raw: String(raw))
            case .float32BE, .float32LE:
                let f = Float(bitPattern: UInt32(raw))
                value = .number(Double(f), raw: f.isFinite ? "\(f)" : "\"\(f)\"")
            default:
                let d = Double(bitPattern: raw)
                value = .number(d, raw: d.isFinite ? "\(d)" : "\"\(d)\"")
            }
            values.append(value)
            offset += width
        }
        let error = bytes.count % width != 0
            ? "Payload length (\(bytes.count) bytes) is not a multiple of \(width); trailing bytes ignored" : nil
        if values.count == 1 {
            return DecodedPayload(kind: .numbers, text: values[0].serialized(), json: .array(values), format: format, error: error)
        }
        let json = JSONValue.array(values)
        return DecodedPayload(kind: .numbers, text: json.serialized(pretty: false), json: json, format: format, error: error)
    }

    static func isMostlyPrintable(_ s: String) -> Bool {
        var control = 0
        var total = 0
        for scalar in s.unicodeScalars {
            total += 1
            if scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t" { control += 1 }
            if scalar == "\u{FFFD}" { control += 1 }
        }
        return total == 0 || Double(control) / Double(total) < 0.05
    }

    /// Classic hex dump: offset, 16 bytes in hex, ASCII column.
    public static func hexDump(_ data: Data, limit: Int = 64 * 1024) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            hex = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex + "  " + ascii)
            offset += 16
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }

    /// One-line preview used in the topic tree.
    public static func preview(_ data: Data, topic: String, maxLength: Int = 120) -> String {
        if data.isEmpty { return "" }
        if isSparkplugTopic(topic), (try? SparkplugDecoder.decode(data)) != nil {
            return "[Sparkplug B, \(data.count) bytes]"
        }
        if let s = String(data: data.prefix(maxLength * 4), encoding: .utf8) ?? String(data: data.prefix(maxLength * 4 - 3), encoding: .utf8),
           isMostlyPrintable(s) {
            var collapsed = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
            if collapsed.count > maxLength { collapsed = String(collapsed.prefix(maxLength)) + "…" }
            return collapsed
        }
        let hex = data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
        return "0x " + hex + (data.count > 24 ? " … (\(data.count) bytes)" : "")
    }

    /// Parse a hex string ("0a ff 01" or "0x0aff01") into bytes.
    public static func data(fromHex string: String) -> Data? {
        var s = string.replacingOccurrences(of: "0x", with: "")
        s.removeAll { $0.isWhitespace || $0 == ":" || $0 == "," }
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let b = UInt8(s[index..<next], radix: 16) else { return nil }
            data.append(b)
            index = next
        }
        return data
    }
}
