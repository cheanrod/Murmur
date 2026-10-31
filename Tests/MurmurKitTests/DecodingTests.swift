import Foundation
import Testing
@testable import MurmurKit

@Suite struct DecodingTests {
    @Test func jsonPreservesKeyOrder() throws {
        let json = try #require(JSONValue.parse(#"{"z":1,"a":[true,null,"x\n"],"m":{"k":-1.5e2}}"#))
        #expect(json.serialized(pretty: false) == #"{"z":1,"a":[true,null,"x\n"],"m":{"k":-1.5e2}}"#)
        #expect(json.value(at: ["m", "k"])?.numericValue == -150)
        #expect(json.value(at: ["a", "0"]) == .bool(true))
    }

    @Test func jsonErrors() {
        #expect(JSONValue.validationError("{\"a\":}") != nil)
        #expect(JSONValue.validationError("[1,2,]") != nil)
        #expect(JSONValue.validationError("{\"a\": \"\\ud83d\\ude00\"}") == nil)
        #expect(JSONValue.parse("\"\\ud83d\\ude00\"") == .string("😀"))
    }

    @Test func autoDecoding() {
        #expect(PayloadDecoder.decode(Data("21.5".utf8), format: .auto).numericValue == 21.5)
        #expect(PayloadDecoder.decode(Data("hello world".utf8), format: .auto).kind == .text)
        #expect(PayloadDecoder.decode(Data(#"{"t":1}"#.utf8), format: .auto).kind == .json)
        #expect(PayloadDecoder.decode(Data([0x00, 0xFF, 0x01, 0x02]), format: .auto).kind == .binary)
        #expect(PayloadDecoder.decode(Data(), format: .auto).kind == .empty)
    }

    @Test func binaryNumbers() {
        #expect(PayloadDecoder.decode(Data([0xFF, 0xFE]), format: .int16BE).numericValue == -2)
        #expect(PayloadDecoder.decode(Data([0x01, 0x00]), format: .uint16LE).numericValue == 1)
        let f: Float = 3.25
        var be = f.bitPattern.bigEndian
        let data = withUnsafeBytes(of: &be) { Data($0) }
        #expect(PayloadDecoder.decode(data, format: .float32BE).numericValue == 3.25)
    }

    @Test func hexParsing() {
        #expect(PayloadDecoder.data(fromHex: "0x0a ff:01") == Data([0x0A, 0xFF, 0x01]))
        #expect(PayloadDecoder.data(fromHex: "abc") == nil)
    }

    /// Hand-encoded Sparkplug B payload: timestamp=1000, seq=3, metric{name="temp", datatype=Double(10), double_value=21.5}
    @Test func sparkplug() throws {
        var metric = Data()
        metric += [0x0A, 0x04] + Array("temp".utf8)     // field 1, string
        metric += [0x20, 0x0A]                          // field 4 varint datatype=10
        var d = (21.5 as Double).bitPattern.littleEndian
        metric += [0x69] + withUnsafeBytes(of: &d) { Array($0) } // field 13 fixed64
        var payload = Data([0x08, 0xE8, 0x07])          // field 1 varint 1000
        payload += [0x12, UInt8(metric.count)] + metric // field 2 metric
        payload += [0x18, 0x03]                         // field 3 seq
        let json = try SparkplugDecoder.decode(payload)
        #expect(json.value(at: ["timestamp"])?.numericValue == 1000)
        #expect(json.value(at: ["seq"])?.numericValue == 3)
        #expect(json.value(at: ["metrics", "0", "name"]) == .string("temp"))
        #expect(json.value(at: ["metrics", "0", "datatype"]) == .string("Double"))
        #expect(json.value(at: ["metrics", "0", "value"])?.numericValue == 21.5)
        let auto = PayloadDecoder.decode(payload, format: .auto, topic: "spBv1.0/group/DDATA/node/dev")
        #expect(auto.kind == .sparkplug)
    }

    @Test func diff() {
        let lines = TextDiff.diff(old: "a\nb\nc", new: "a\nx\nc\nd")
        #expect(lines.map(\.kind) == [.same, .removed, .added, .same, .added])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["x", "d"])
    }
}
