import Foundation
import Testing
@testable import MurmurKit

@Suite struct CodecTests {
    func roundTrip(_ packet: MQTTPacket, _ version: MQTTVersion) throws -> MQTTPacket {
        var data = PacketCodec.encode(packet, version: version)
        let decoded = try #require(try PacketCodec.extractPacket(from: &data, version: version))
        #expect(data.isEmpty)
        return decoded
    }

    @Test(arguments: [MQTTVersion.v311, .v5])
    func publishRoundTrip(version: MQTTVersion) throws {
        var props = MQTTProperties()
        if version == .v5 {
            props.add(0x03, .string("application/json"))
            props.add(0x26, .pair("k", "v"))
        }
        let p = PublishPacket(topic: "a/b/c", payload: Data("{\"x\":1}".utf8), qos: .exactlyOnce, retain: true,
                              dup: false, packetID: 42, properties: props)
        #expect(try roundTrip(.publish(p), version) == .publish(p))
    }

    @Test func remainingLengthVarint() throws {
        let big = Data(repeating: 0x41, count: 300_000)
        let p = PublishPacket(topic: "t", payload: big, qos: .atMostOnce, retain: false, dup: false, packetID: nil,
                              properties: MQTTProperties())
        var data = PacketCodec.encode(.publish(p), version: .v311)
        #expect(data[1] & 0x80 != 0) // multi-byte length
        // Partial data yields nil and consumes nothing.
        var partial = data.prefix(1000)
        #expect(try PacketCodec.extractPacket(from: &partial, version: .v311) == nil)
        #expect(partial.count == 1000)
        let decoded = try PacketCodec.extractPacket(from: &data, version: .v311)
        #expect(decoded == .publish(p))
    }

    @Test func connectEncodesCredentialsAndWill() throws {
        let opts = ConnectOptions(clientID: "c1", username: "u", password: "p", cleanSession: true, keepAlive: 30,
                                  will: LastWill(topic: "w", payload: "bye", qos: .atLeastOnce, retain: true), version: .v5)
        let decoded = try roundTrip(.connect(opts), .v5)
        guard case .connect(let o) = decoded else { Issue.record("not connect"); return }
        #expect(o.clientID == "c1")
        #expect(o.username == "u")
        #expect(o.password == "p")
        #expect(o.keepAlive == 30)
        #expect(o.will?.topic == "w")
        #expect(o.will?.qos == .atLeastOnce)
        #expect(o.version == .v5)
    }

    @Test func connackV5Properties() throws {
        var props = MQTTProperties()
        props.add(0x12, .string("assigned-id"))
        props.add(0x13, .u16(20))
        let ack = ConnAck(sessionPresent: true, code: 0, properties: props)
        guard case .connack(let a) = try roundTrip(.connack(ack), .v5) else { Issue.record(); return }
        #expect(a.assignedClientID == "assigned-id")
        #expect(a.serverKeepAlive == 20)
        #expect(a.sessionPresent)
    }

    @Test func subscribeAndAcks() throws {
        let subs = [SubscriptionRequest(topicFilter: "#", qos: .atMostOnce), SubscriptionRequest(topicFilter: "$SYS/#", qos: .exactlyOnce)]
        #expect(try roundTrip(.subscribe(id: 7, subs), .v5) == .subscribe(id: 7, subs))
        #expect(try roundTrip(.suback(id: 7, codes: [0, 0x80]), .v311) == .suback(id: 7, codes: [0, 0x80]))
        #expect(try roundTrip(.pubrel(id: 9, reason: 0), .v5) == .pubrel(id: 9, reason: 0))
        #expect(PacketCodec.encode(.pubrel(id: 9, reason: 0), version: .v311)[0] == 0x62)
        #expect(PacketCodec.encode(.pingreq, version: .v311) == Data([0xC0, 0x00]))
    }

    @Test func topicMatching() {
        #expect(TopicValidation.matches(filter: "#", topic: "a/b"))
        #expect(!TopicValidation.matches(filter: "#", topic: "$SYS/x"))
        #expect(TopicValidation.matches(filter: "$SYS/#", topic: "$SYS/broker/uptime"))
        #expect(TopicValidation.matches(filter: "a/+/c", topic: "a/b/c"))
        #expect(!TopicValidation.matches(filter: "a/+/c", topic: "a/b/d"))
        #expect(TopicValidation.matches(filter: "a/#", topic: "a"))
        #expect(TopicValidation.validateFilter("a/#/b") != nil)
        #expect(TopicValidation.validateFilter("a/b+") != nil)
        #expect(TopicValidation.validatePublishTopic("a/+") != nil)
    }
}
