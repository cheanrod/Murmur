import Foundation

/// Minimal protobuf wire-format reader.
struct ProtobufReader {
    enum WireValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited(Data)
        case fixed32(UInt32)
    }

    struct DecodeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let bytes: [UInt8]
    private var i = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { i >= bytes.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw DecodeError(message: "varint too long") }
        }
        throw DecodeError(message: "truncated varint")
    }

    mutating func next() throws -> (field: Int, value: WireValue)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        guard field > 0 else { throw DecodeError(message: "invalid field number 0") }
        switch key & 0x07 {
        case 0: return (field, .varint(try readVarint()))
        case 1:
            guard i + 8 <= bytes.count else { throw DecodeError(message: "truncated fixed64") }
            var v: UInt64 = 0
            for k in (0..<8).reversed() { v = v << 8 | UInt64(bytes[i + k]) }
            i += 8
            return (field, .fixed64(v))
        case 2:
            let len = Int(try readVarint())
            guard len >= 0, i + len <= bytes.count else { throw DecodeError(message: "truncated length-delimited field") }
            let d = Data(bytes[i..<(i + len)])
            i += len
            return (field, .lengthDelimited(d))
        case 5:
            guard i + 4 <= bytes.count else { throw DecodeError(message: "truncated fixed32") }
            var v: UInt32 = 0
            for k in (0..<4).reversed() { v = v << 8 | UInt32(bytes[i + k]) }
            i += 4
            return (field, .fixed32(v))
        default:
            throw DecodeError(message: "unsupported wire type \(key & 7)")
        }
    }
}

/// Decodes Eclipse Sparkplug B payloads (spBv1.0) into a JSON representation.
public enum SparkplugDecoder {
    static let dataTypes: [UInt64: String] = [
        1: "Int8", 2: "Int16", 3: "Int32", 4: "Int64", 5: "UInt8", 6: "UInt16", 7: "UInt32", 8: "UInt64",
        9: "Float", 10: "Double", 11: "Boolean", 12: "String", 13: "DateTime", 14: "Text", 15: "UUID",
        16: "DataSet", 17: "Bytes", 18: "File", 19: "Template", 20: "PropertySet", 21: "PropertySetList",
        22: "Int8Array", 23: "Int16Array", 24: "Int32Array", 25: "Int64Array", 26: "UInt8Array",
        27: "UInt16Array", 28: "UInt32Array", 29: "UInt64Array", 30: "FloatArray", 31: "DoubleArray",
        32: "BooleanArray", 33: "StringArray", 34: "DateTimeArray",
    ]

    public static func decode(_ data: Data) throws -> JSONValue {
        var r = ProtobufReader(data)
        var out: [(String, JSONValue)] = []
        var metrics: [JSONValue] = []
        var sawKnownField = false
        while let (field, value) = try r.next() {
            switch (field, value) {
            case (1, .varint(let v)):
                out.append(("timestamp", .number(Double(v), raw: String(v)))); sawKnownField = true
            case (2, .lengthDelimited(let d)):
                metrics.append(try decodeMetric(d)); sawKnownField = true
            case (3, .varint(let v)):
                out.append(("seq", .number(Double(v), raw: String(v)))); sawKnownField = true
            case (4, .lengthDelimited(let d)):
                out.append(("uuid", .string(String(decoding: d, as: UTF8.self))))
            case (5, .lengthDelimited(let d)):
                out.append(("body", .string(d.base64EncodedString())))
            default:
                break
            }
        }
        guard sawKnownField || data.isEmpty else { throw ProtobufReader.DecodeError(message: "no Sparkplug fields found") }
        out.append(("metrics", .array(metrics)))
        return .object(out)
    }

    static func decodeMetric(_ data: Data) throws -> JSONValue {
        var r = ProtobufReader(data)
        var out: [(String, JSONValue)] = []
        var datatype: UInt64 = 0
        var value: JSONValue?
        while let (field, wire) = try r.next() {
            switch (field, wire) {
            case (1, .lengthDelimited(let d)): out.append(("name", .string(String(decoding: d, as: UTF8.self))))
            case (2, .varint(let v)): out.append(("alias", .number(Double(v), raw: String(v))))
            case (3, .varint(let v)): out.append(("timestamp", .number(Double(v), raw: String(v))))
            case (4, .varint(let v)): datatype = v
            case (5, .varint(let v)): out.append(("is_historical", .bool(v != 0)))
            case (6, .varint(let v)): out.append(("is_transient", .bool(v != 0)))
            case (7, .varint(let v)): if v != 0 { value = .null }
            case (8, .lengthDelimited(let d)): out.append(("metadata", try decodeGeneric(d)))
            case (9, .lengthDelimited(let d)): out.append(("properties", try decodeGeneric(d)))
            case (10, .varint(let v)):
                let u = UInt32(truncatingIfNeeded: v)
                switch datatype {
                case 1: value = .number(Double(Int8(truncatingIfNeeded: u)))
                case 2: value = .number(Double(Int16(truncatingIfNeeded: u)))
                case 3: value = .number(Double(Int32(bitPattern: u)))
                default: value = .number(Double(u))
                }
            case (11, .varint(let v)):
                if datatype == 4 {
                    let s = Int64(bitPattern: v)
                    value = .number(Double(s), raw: String(s))
                } else {
                    value = .number(Double(v), raw: String(v))
                }
            case (12, .fixed32(let v)):
                let f = Float(bitPattern: v)
                value = .number(Double(f), raw: f.isFinite ? "\(f)" : "null")
            case (13, .fixed64(let v)):
                let d = Double(bitPattern: v)
                value = .number(d, raw: d.isFinite ? "\(d)" : "null")
            case (14, .varint(let v)): value = .bool(v != 0)
            case (15, .lengthDelimited(let d)): value = .string(String(decoding: d, as: UTF8.self))
            case (16, .lengthDelimited(let d)): value = .string(d.base64EncodedString())
            case (17, .lengthDelimited(let d)), (18, .lengthDelimited(let d)), (19, .lengthDelimited(let d)):
                value = try decodeGeneric(d)
            default: break
            }
        }
        out.append(("datatype", .string(dataTypes[datatype] ?? "Unknown(\(datatype))")))
        out.append(("value", value ?? .null))
        return .object(out)
    }

    /// Schema-less decode of a nested message (datasets, templates, property sets, metadata).
    static func decodeGeneric(_ data: Data, depth: Int = 0) throws -> JSONValue {
        var r = ProtobufReader(data)
        var out: [(String, JSONValue)] = []
        while let (field, wire) = try r.next() {
            let key = "field_\(field)"
            let v: JSONValue
            switch wire {
            case .varint(let x): v = .number(Double(x), raw: String(x))
            case .fixed32(let x): v = .number(Double(Float(bitPattern: x)))
            case .fixed64(let x): v = .number(Double(bitPattern: x))
            case .lengthDelimited(let d):
                if depth < 8, !d.isEmpty, let nested = try? decodeGeneric(d, depth: depth + 1), case .object(let o) = nested, !o.isEmpty {
                    v = nested
                } else if let s = String(data: d, encoding: .utf8), PayloadDecoder.isMostlyPrintable(s) {
                    v = .string(s)
                } else {
                    v = .string(d.base64EncodedString())
                }
            }
            out.append((key, v))
        }
        return .object(out)
    }
}
