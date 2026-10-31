import Foundation

public enum PacketType: UInt8, Sendable {
    case connect = 1, connack, publish, puback, pubrec, pubrel, pubcomp
    case subscribe, suback, unsubscribe, unsuback, pingreq, pingresp, disconnect, auth
}

// MARK: - Byte writer / reader

struct ByteWriter {
    var data = Data()

    mutating func byte(_ b: UInt8) { data.append(b) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF)) }
    mutating func u32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF)); data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF)); data.append(UInt8(v & 0xFF))
    }
    mutating func varint(_ value: Int) { data.append(contentsOf: ByteWriter.encodeVarint(value)) }
    mutating func string(_ s: String) { binary(Data(s.utf8)) }
    mutating func binary(_ d: Data) { u16(UInt16(min(d.count, 65535))); data.append(d.prefix(65535)) }
    mutating func raw(_ d: Data) { data.append(d) }

    static func encodeVarint(_ value: Int) -> [UInt8] {
        var x = value
        var out: [UInt8] = []
        repeat {
            var b = UInt8(x % 128)
            x /= 128
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }
}

struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }
    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func byte() throws -> UInt8 {
        guard offset < data.endIndex else { throw MQTTError.malformedPacket("unexpected end of data") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 { UInt16(try byte()) << 8 | UInt16(try byte()) }

    mutating func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = v << 8 | UInt32(try byte()) }
        return v
    }

    mutating func varint() throws -> Int {
        var multiplier = 1
        var value = 0
        for _ in 0..<4 {
            let b = try byte()
            value += Int(b & 0x7F) * multiplier
            if b & 0x80 == 0 { return value }
            multiplier *= 128
        }
        throw MQTTError.malformedPacket("variable byte integer too long")
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw MQTTError.malformedPacket("length exceeds packet") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func binary() throws -> Data { try bytes(Int(try u16())) }

    mutating func string() throws -> String {
        let d = try binary()
        guard let s = String(data: d, encoding: .utf8) else { throw MQTTError.malformedPacket("invalid UTF-8 string") }
        return s
    }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }
}

// MARK: - MQTT 5 properties

/// Generic MQTT 5 property bag used for decoding and encoding.
public struct MQTTProperties: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case byte(UInt8), u16(UInt16), u32(UInt32), varint(Int), string(String), binary(Data), pair(String, String)
    }

    public var items: [(UInt8, Value)] = []

    public init() {}

    public static func == (lhs: MQTTProperties, rhs: MQTTProperties) -> Bool {
        lhs.items.count == rhs.items.count && zip(lhs.items, rhs.items).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    public mutating func add(_ id: UInt8, _ value: Value) { items.append((id, value)) }

    public func first(_ id: UInt8) -> Value? { items.first(where: { $0.0 == id })?.1 }

    func byte(_ id: UInt8) -> UInt8? { if case .byte(let v)? = first(id) { return v }; return nil }
    func u16(_ id: UInt8) -> UInt16? { if case .u16(let v)? = first(id) { return v }; return nil }
    func u32(_ id: UInt8) -> UInt32? { if case .u32(let v)? = first(id) { return v }; return nil }
    func string(_ id: UInt8) -> String? { if case .string(let v)? = first(id) { return v }; return nil }
    func binary(_ id: UInt8) -> Data? { if case .binary(let v)? = first(id) { return v }; return nil }

    var userProperties: [UserProperty] {
        items.compactMap { if case .pair(let k, let v) = $0.1, $0.0 == 0x26 { return UserProperty(key: k, value: v) }; return nil }
    }

    static func kind(of id: UInt8) -> Int? {
        switch id {
        case 0x01, 0x17, 0x19, 0x24, 0x25, 0x28, 0x29, 0x2A: 0 // byte
        case 0x13, 0x21, 0x22, 0x23: 1 // u16
        case 0x02, 0x11, 0x18, 0x27: 2 // u32
        case 0x0B: 3 // varint
        case 0x03, 0x08, 0x12, 0x15, 0x1A, 0x1C, 0x1F: 4 // string
        case 0x09, 0x16: 5 // binary
        case 0x26: 6 // string pair
        default: nil
        }
    }

    static func decode(_ reader: inout ByteReader) throws -> MQTTProperties {
        let length = try reader.varint()
        var sub = ByteReader(try reader.bytes(length))
        var props = MQTTProperties()
        while !sub.isAtEnd {
            let id = UInt8(try sub.varint())
            guard let kind = kind(of: id) else { throw MQTTError.malformedPacket(String(format: "unknown property 0x%02X", id)) }
            let value: Value
            switch kind {
            case 0: value = .byte(try sub.byte())
            case 1: value = .u16(try sub.u16())
            case 2: value = .u32(try sub.u32())
            case 3: value = .varint(try sub.varint())
            case 4: value = .string(try sub.string())
            case 5: value = .binary(try sub.binary())
            default: value = .pair(try sub.string(), try sub.string())
            }
            props.add(id, value)
        }
        return props
    }

    func encode(into writer: inout ByteWriter) {
        var body = ByteWriter()
        for (id, value) in items {
            body.varint(Int(id))
            switch value {
            case .byte(let v): body.byte(v)
            case .u16(let v): body.u16(v)
            case .u32(let v): body.u32(v)
            case .varint(let v): body.varint(v)
            case .string(let v): body.string(v)
            case .binary(let v): body.binary(v)
            case .pair(let k, let v): body.string(k); body.string(v)
            }
        }
        writer.varint(body.data.count)
        writer.raw(body.data)
    }
}

extension PublishProperties {
    init(_ p: MQTTProperties) {
        self.init()
        payloadFormatIndicator = p.byte(0x01)
        messageExpiryInterval = p.u32(0x02)
        contentType = p.string(0x03)
        responseTopic = p.string(0x08)
        correlationData = p.binary(0x09)
        userProperties = p.userProperties
        topicAlias = p.u16(0x23)
        subscriptionIdentifiers = p.items.compactMap { if $0.0 == 0x0B, case .varint(let v) = $0.1 { return v }; return nil }
    }

    var mqttProperties: MQTTProperties {
        var p = MQTTProperties()
        if let v = payloadFormatIndicator { p.add(0x01, .byte(v)) }
        if let v = messageExpiryInterval { p.add(0x02, .u32(v)) }
        if let v = contentType, !v.isEmpty { p.add(0x03, .string(v)) }
        if let v = responseTopic, !v.isEmpty { p.add(0x08, .string(v)) }
        if let v = correlationData, !v.isEmpty { p.add(0x09, .binary(v)) }
        for up in userProperties where !up.key.isEmpty { p.add(0x26, .pair(up.key, up.value)) }
        return p
    }
}

// MARK: - Packets

public struct ConnectOptions: Sendable {
    public var clientID: String
    public var username: String?
    public var password: String?
    public var cleanSession: Bool
    public var keepAlive: UInt16
    public var will: LastWill?
    public var version: MQTTVersion
    public var sessionExpiry: UInt32?

    public init(
        clientID: String, username: String? = nil, password: String? = nil, cleanSession: Bool = true,
        keepAlive: UInt16 = 60, will: LastWill? = nil, version: MQTTVersion = .v311, sessionExpiry: UInt32? = nil
    ) {
        self.clientID = clientID
        self.username = username
        self.password = password
        self.cleanSession = cleanSession
        self.keepAlive = keepAlive
        self.will = will
        self.version = version
        self.sessionExpiry = sessionExpiry
    }
}

public struct ConnAck: Sendable, Equatable {
    public var sessionPresent: Bool
    public var code: UInt8
    public var properties: MQTTProperties

    public var assignedClientID: String? { properties.string(0x12) }
    public var serverKeepAlive: UInt16? { properties.u16(0x13) }
    public var receiveMaximum: UInt16? { properties.u16(0x21) }
    public var topicAliasMaximum: UInt16? { properties.u16(0x22) }
    public var maximumQoS: UInt8? { properties.byte(0x24) }
    public var retainAvailable: Bool? { properties.byte(0x25).map { $0 == 1 } }
    public var maximumPacketSize: UInt32? { properties.u32(0x27) }
    public var reasonString: String? { properties.string(0x1F) }

    public init(sessionPresent: Bool, code: UInt8, properties: MQTTProperties = MQTTProperties()) {
        self.sessionPresent = sessionPresent
        self.code = code
        self.properties = properties
    }
}

public struct PublishPacket: Sendable, Equatable {
    public var topic: String
    public var payload: Data
    public var qos: QoS
    public var retain: Bool
    public var dup: Bool
    public var packetID: UInt16?
    public var properties: MQTTProperties

    public init(topic: String, payload: Data, qos: QoS, retain: Bool, dup: Bool = false, packetID: UInt16?,
                properties: MQTTProperties = MQTTProperties()) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
        self.dup = dup
        self.packetID = packetID
        self.properties = properties
    }
}

public enum MQTTPacket: Sendable, Equatable {
    case connect(ConnectOptions)
    case connack(ConnAck)
    case publish(PublishPacket)
    case puback(id: UInt16, reason: UInt8)
    case pubrec(id: UInt16, reason: UInt8)
    case pubrel(id: UInt16, reason: UInt8)
    case pubcomp(id: UInt16, reason: UInt8)
    case subscribe(id: UInt16, [SubscriptionRequest])
    case suback(id: UInt16, codes: [UInt8])
    case unsubscribe(id: UInt16, [String])
    case unsuback(id: UInt16, codes: [UInt8])
    case pingreq
    case pingresp
    case disconnect(reason: UInt8, reasonString: String?)
    case auth(reason: UInt8)

    public static func == (lhs: MQTTPacket, rhs: MQTTPacket) -> Bool {
        switch (lhs, rhs) {
        case (.connect, .connect): return true
        case let (.connack(a), .connack(b)): return a == b
        case let (.publish(a), .publish(b)): return a == b
        case let (.puback(a, b), .puback(c, d)), let (.pubrec(a, b), .pubrec(c, d)),
            let (.pubrel(a, b), .pubrel(c, d)), let (.pubcomp(a, b), .pubcomp(c, d)):
            return a == c && b == d
        case let (.subscribe(a, b), .subscribe(c, d)): return a == c && b == d
        case let (.suback(a, b), .suback(c, d)), let (.unsuback(a, b), .unsuback(c, d)): return a == c && b == d
        case let (.unsubscribe(a, b), .unsubscribe(c, d)): return a == c && b == d
        case (.pingreq, .pingreq), (.pingresp, .pingresp): return true
        case let (.disconnect(a, b), .disconnect(c, d)): return a == c && b == d
        case let (.auth(a), .auth(b)): return a == b
        default: return false
        }
    }
}

public enum PacketCodec {
    // MARK: Encoding

    public static func encode(_ packet: MQTTPacket, version: MQTTVersion) -> Data {
        let v5 = version == .v5
        var body = ByteWriter()
        let header: UInt8

        switch packet {
        case .connect(let o):
            header = 0x10
            body.string("MQTT")
            body.byte(o.version.protocolLevel)
            var flags: UInt8 = 0
            if o.cleanSession { flags |= 0x02 }
            if let w = o.will {
                flags |= 0x04 | (w.qos.rawValue << 3)
                if w.retain { flags |= 0x20 }
            }
            if let p = o.password, !p.isEmpty { flags |= 0x40 }
            if let u = o.username, !u.isEmpty { flags |= 0x80 }
            // 3.1.1 requires a username when a password is present.
            if flags & 0x40 != 0, flags & 0x80 == 0, o.version == .v311 { flags |= 0x80 }
            body.byte(flags)
            body.u16(o.keepAlive)
            if o.version == .v5 {
                var p = MQTTProperties()
                if let e = o.sessionExpiry, e > 0 { p.add(0x11, .u32(e)) }
                p.add(0x21, .u16(65535)) // receive maximum
                p.add(0x22, .u16(0)) // no topic aliases from server
                p.encode(into: &body)
            }
            body.string(o.clientID)
            if let w = o.will {
                if o.version == .v5 { MQTTProperties().encode(into: &body) }
                body.string(w.topic)
                body.binary(Data(w.payload.utf8))
            }
            if flags & 0x80 != 0 { body.string(o.username ?? "") }
            if flags & 0x40 != 0 { body.binary(Data((o.password ?? "").utf8)) }

        case .connack(let c):
            header = 0x20
            body.byte(c.sessionPresent ? 1 : 0)
            body.byte(c.code)
            if v5 { c.properties.encode(into: &body) }

        case .publish(let p):
            var h: UInt8 = 0x30 | (p.qos.rawValue << 1)
            if p.retain { h |= 0x01 }
            if p.dup { h |= 0x08 }
            header = h
            body.string(p.topic)
            if p.qos != .atMostOnce { body.u16(p.packetID ?? 0) }
            if v5 { p.properties.encode(into: &body) }
            body.raw(p.payload)

        case .puback(let id, let r), .pubrec(let id, let r), .pubrel(let id, let r), .pubcomp(let id, let r):
            switch packet {
            case .puback: header = 0x40
            case .pubrec: header = 0x50
            case .pubrel: header = 0x62
            default: header = 0x70
            }
            body.u16(id)
            if v5 && r != 0 { body.byte(r) }

        case .subscribe(let id, let subs):
            header = 0x82
            body.u16(id)
            if v5 { MQTTProperties().encode(into: &body) }
            for s in subs {
                body.string(s.topicFilter)
                body.byte(s.qos.rawValue)
            }

        case .suback(let id, let codes), .unsuback(let id, let codes):
            if case .suback = packet { header = 0x90 } else { header = 0xB0 }
            body.u16(id)
            if v5 { MQTTProperties().encode(into: &body) }
            for c in codes { body.byte(c) }

        case .unsubscribe(let id, let filters):
            header = 0xA2
            body.u16(id)
            if v5 { MQTTProperties().encode(into: &body) }
            for f in filters { body.string(f) }

        case .pingreq: header = 0xC0
        case .pingresp: header = 0xD0

        case .disconnect(let reason, _):
            header = 0xE0
            if v5 && reason != 0 { body.byte(reason) }

        case .auth(let reason):
            header = 0xF0
            if reason != 0 { body.byte(reason) }
        }

        var out = Data([header])
        out.append(contentsOf: ByteWriter.encodeVarint(body.data.count))
        out.append(body.data)
        return out
    }

    // MARK: Decoding

    /// Attempts to extract one complete packet from the front of `buffer`.
    /// Returns nil if more data is needed. Consumed bytes are removed from `buffer`.
    public static func extractPacket(from buffer: inout Data, version: MQTTVersion) throws -> MQTTPacket? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        var multiplier = 1
        var length = 0
        var idx = start + 1
        while true {
            guard idx < buffer.endIndex else { return nil }
            let b = buffer[idx]
            length += Int(b & 0x7F) * multiplier
            idx += 1
            if b & 0x80 == 0 { break }
            multiplier *= 128
            if idx - start > 4 { throw MQTTError.malformedPacket("remaining length too long") }
        }
        guard buffer.endIndex - idx >= length else { return nil }
        let header = buffer[start]
        let body = buffer.subdata(in: idx..<(idx + length))
        buffer.removeSubrange(start..<(idx + length))
        if buffer.isEmpty { buffer = Data() } // reset indices
        return try decode(header: header, body: body, version: version)
    }

    public static func decode(header: UInt8, body: Data, version: MQTTVersion) throws -> MQTTPacket {
        guard let type = PacketType(rawValue: header >> 4) else { throw MQTTError.malformedPacket("reserved packet type") }
        let v5 = version == .v5
        var r = ByteReader(body)

        func ackReason() throws -> UInt8 { r.isAtEnd || !v5 ? 0 : try r.byte() }

        switch type {
        case .connack:
            let flags = try r.byte()
            let code = try r.byte()
            let props = v5 && !r.isAtEnd ? try MQTTProperties.decode(&r) : MQTTProperties()
            return .connack(ConnAck(sessionPresent: flags & 1 == 1, code: code, properties: props))

        case .publish:
            guard let qos = QoS(rawValue: (header >> 1) & 0x03) else { throw MQTTError.malformedPacket("invalid QoS 3") }
            let topic = try r.string()
            let id = qos != .atMostOnce ? try r.u16() : nil
            let props = v5 ? try MQTTProperties.decode(&r) : MQTTProperties()
            return .publish(PublishPacket(
                topic: topic, payload: r.rest(), qos: qos, retain: header & 0x01 == 1,
                dup: header & 0x08 != 0, packetID: id, properties: props))

        case .puback: let id = try r.u16(); return .puback(id: id, reason: try ackReason())
        case .pubrec: let id = try r.u16(); return .pubrec(id: id, reason: try ackReason())
        case .pubrel: let id = try r.u16(); return .pubrel(id: id, reason: try ackReason())
        case .pubcomp: let id = try r.u16(); return .pubcomp(id: id, reason: try ackReason())

        case .suback, .unsuback:
            let id = try r.u16()
            if v5 { _ = try MQTTProperties.decode(&r) }
            var codes: [UInt8] = []
            while !r.isAtEnd { codes.append(try r.byte()) }
            return type == .suback ? .suback(id: id, codes: codes) : .unsuback(id: id, codes: codes)

        case .subscribe:
            let id = try r.u16()
            if v5 { _ = try MQTTProperties.decode(&r) }
            var subs: [SubscriptionRequest] = []
            while !r.isAtEnd {
                let f = try r.string()
                subs.append(SubscriptionRequest(topicFilter: f, qos: QoS(rawValue: try r.byte() & 0x03) ?? .atMostOnce))
            }
            return .subscribe(id: id, subs)

        case .unsubscribe:
            let id = try r.u16()
            if v5 { _ = try MQTTProperties.decode(&r) }
            var filters: [String] = []
            while !r.isAtEnd { filters.append(try r.string()) }
            return .unsubscribe(id: id, filters)

        case .pingreq: return .pingreq
        case .pingresp: return .pingresp

        case .disconnect:
            let reason = r.isAtEnd ? 0 : try r.byte()
            var reasonString: String?
            if v5 && !r.isAtEnd { reasonString = try MQTTProperties.decode(&r).string(0x1F) }
            return .disconnect(reason: reason, reasonString: reasonString)

        case .auth:
            return .auth(reason: r.isAtEnd ? 0 : try r.byte())

        case .connect:
            // Only needed for tests / fake brokers: minimal parse.
            _ = try r.string()
            let level = try r.byte()
            let flags = try r.byte()
            let keepAlive = try r.u16()
            let connectVersion: MQTTVersion = level == 5 ? .v5 : .v311
            if connectVersion == .v5 { _ = try MQTTProperties.decode(&r) }
            let clientID = try r.string()
            var will: LastWill?
            if flags & 0x04 != 0 {
                if connectVersion == .v5 { _ = try MQTTProperties.decode(&r) }
                let t = try r.string()
                let p = try r.binary()
                will = LastWill(topic: t, payload: String(decoding: p, as: UTF8.self),
                                qos: QoS(rawValue: (flags >> 3) & 3) ?? .atMostOnce, retain: flags & 0x20 != 0)
            }
            let user = flags & 0x80 != 0 ? try r.string() : nil
            let pass = flags & 0x40 != 0 ? String(decoding: try r.binary(), as: UTF8.self) : nil
            return .connect(ConnectOptions(clientID: clientID, username: user, password: pass,
                                           cleanSession: flags & 0x02 != 0, keepAlive: keepAlive,
                                           will: will, version: connectVersion))
        }
    }
}
