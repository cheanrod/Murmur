import Foundation

/// MQTT protocol level negotiated in CONNECT.
public enum MQTTVersion: String, Codable, CaseIterable, Sendable, Identifiable {
    case v311 = "3.1.1"
    case v5 = "5.0"

    public var id: String { rawValue }

    var protocolLevel: UInt8 {
        switch self {
        case .v311: 4
        case .v5: 5
        }
    }
}

public enum QoS: UInt8, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case atMostOnce = 0
    case atLeastOnce = 1
    case exactlyOnce = 2

    public var id: UInt8 { rawValue }
    public var label: String { "QoS \(rawValue)" }

    public static func < (lhs: QoS, rhs: QoS) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// MQTT 5 user property (key/value string pair). Order and duplicates are significant.
public struct UserProperty: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case key, value }
}

/// The subset of MQTT 5 PUBLISH properties that is meaningful to a client UI.
public struct PublishProperties: Hashable, Sendable {
    public var payloadFormatIndicator: UInt8?
    public var messageExpiryInterval: UInt32?
    public var contentType: String?
    public var responseTopic: String?
    public var correlationData: Data?
    public var userProperties: [UserProperty] = []
    public var subscriptionIdentifiers: [Int] = []
    public var topicAlias: UInt16?

    public init(
        payloadFormatIndicator: UInt8? = nil,
        messageExpiryInterval: UInt32? = nil,
        contentType: String? = nil,
        responseTopic: String? = nil,
        correlationData: Data? = nil,
        userProperties: [UserProperty] = []
    ) {
        self.payloadFormatIndicator = payloadFormatIndicator
        self.messageExpiryInterval = messageExpiryInterval
        self.contentType = contentType
        self.responseTopic = responseTopic
        self.correlationData = correlationData
        self.userProperties = userProperties
    }

    public var isEmpty: Bool {
        payloadFormatIndicator == nil && messageExpiryInterval == nil && contentType == nil
            && responseTopic == nil && correlationData == nil && userProperties.isEmpty
            && subscriptionIdentifiers.isEmpty
    }
}

/// A message received from (or sent to) the broker.
public struct MQTTMessage: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let topic: String
    public let payload: Data
    public let qos: QoS
    public let retain: Bool
    public let received: Date
    public let properties: PublishProperties?

    public init(
        id: UUID = UUID(),
        topic: String,
        payload: Data,
        qos: QoS = .atMostOnce,
        retain: Bool = false,
        received: Date = Date(),
        properties: PublishProperties? = nil
    ) {
        self.id = id
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
        self.received = received
        self.properties = properties
    }
}

/// Last will message configured on CONNECT.
public struct LastWill: Codable, Hashable, Sendable {
    public var topic: String
    public var payload: String
    public var qos: QoS
    public var retain: Bool

    public init(topic: String = "", payload: String = "", qos: QoS = .atMostOnce, retain: Bool = false) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
    }
}

public struct SubscriptionRequest: Hashable, Sendable {
    public var topicFilter: String
    public var qos: QoS
    public init(topicFilter: String, qos: QoS) {
        self.topicFilter = topicFilter
        self.qos = qos
    }
}

public enum MQTTError: LocalizedError, Equatable, Sendable {
    case malformedPacket(String)
    case connectionRefused(code: UInt8, reason: String)
    case transport(String)
    case timeout
    case protocolViolation(String)
    case notConnected
    case invalidTopic(String)

    public var errorDescription: String? {
        switch self {
        case .malformedPacket(let s): "Malformed packet: \(s)"
        case .connectionRefused(let code, let reason): "Connection refused (\(code)): \(reason)"
        case .transport(let s): s
        case .timeout: "Timed out waiting for the broker"
        case .protocolViolation(let s): "Protocol violation: \(s)"
        case .notConnected: "Not connected"
        case .invalidTopic(let s): "Invalid topic: \(s)"
        }
    }
}

public enum ReasonCodes {
    /// Human readable text for a CONNACK return code (3.1.1) or reason code (5.0).
    public static func connack(_ code: UInt8, version: MQTTVersion) -> String {
        if version == .v311 {
            switch code {
            case 0: return "Connection accepted"
            case 1: return "Unacceptable protocol version"
            case 2: return "Identifier rejected"
            case 3: return "Server unavailable"
            case 4: return "Bad user name or password"
            case 5: return "Not authorized"
            default: return "Unknown return code"
            }
        }
        return reason(code)
    }

    public static func reason(_ code: UInt8) -> String {
        switch code {
        case 0x00: "Success"
        case 0x01: "Granted QoS 1"
        case 0x02: "Granted QoS 2"
        case 0x04: "Disconnect with will message"
        case 0x10: "No matching subscribers"
        case 0x11: "No subscription existed"
        case 0x80: "Unspecified error"
        case 0x81: "Malformed packet"
        case 0x82: "Protocol error"
        case 0x83: "Implementation specific error"
        case 0x84: "Unsupported protocol version"
        case 0x85: "Client identifier not valid"
        case 0x86: "Bad user name or password"
        case 0x87: "Not authorized"
        case 0x88: "Server unavailable"
        case 0x89: "Server busy"
        case 0x8A: "Banned"
        case 0x8B: "Server shutting down"
        case 0x8C: "Bad authentication method"
        case 0x8D: "Keep alive timeout"
        case 0x8E: "Session taken over"
        case 0x8F: "Topic filter invalid"
        case 0x90: "Topic name invalid"
        case 0x91: "Packet identifier in use"
        case 0x92: "Packet identifier not found"
        case 0x93: "Receive maximum exceeded"
        case 0x94: "Topic alias invalid"
        case 0x95: "Packet too large"
        case 0x96: "Message rate too high"
        case 0x97: "Quota exceeded"
        case 0x98: "Administrative action"
        case 0x99: "Payload format invalid"
        case 0x9A: "Retain not supported"
        case 0x9B: "QoS not supported"
        case 0x9C: "Use another server"
        case 0x9D: "Server moved"
        case 0x9E: "Shared subscriptions not supported"
        case 0x9F: "Connection rate exceeded"
        case 0xA0: "Maximum connect time"
        case 0xA1: "Subscription identifiers not supported"
        case 0xA2: "Wildcard subscriptions not supported"
        default: String(format: "Reason code 0x%02X", code)
        }
    }
}

public enum TopicValidation {
    /// Topic names used for PUBLISH must not contain wildcards and must not be empty.
    public static func validatePublishTopic(_ topic: String) -> String? {
        if topic.isEmpty { return "Topic must not be empty" }
        if topic.contains("+") || topic.contains("#") { return "Topic must not contain wildcards (+ or #)" }
        if topic.contains("\u{0}") { return "Topic must not contain NUL characters" }
        if topic.utf8.count > 65535 { return "Topic is too long" }
        return nil
    }

    /// Validates a topic filter used for SUBSCRIBE.
    public static func validateFilter(_ filter: String) -> String? {
        if filter.isEmpty { return "Topic filter must not be empty" }
        let levels = filter.split(separator: "/", omittingEmptySubsequences: false)
        for (index, level) in levels.enumerated() {
            if level.contains("#") && (level != "#" || index != levels.count - 1) {
                return "'#' must be the last level on its own"
            }
            if level.contains("+") && level != "+" {
                return "'+' must occupy an entire level"
            }
        }
        return nil
    }

    /// Whether `topic` matches the subscription `filter` (supports + and #, and $-topic rules).
    public static func matches(filter: String, topic: String) -> Bool {
        var f = filter
        if f.hasPrefix("$share/") {
            // $share/{group}/{filter}
            let parts = f.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            f = parts.count == 3 ? String(parts[2]) : f
        }
        let fl = f.split(separator: "/", omittingEmptySubsequences: false)
        let tl = topic.split(separator: "/", omittingEmptySubsequences: false)
        if topic.hasPrefix("$"), let first = fl.first, first == "#" || first == "+" { return false }
        var i = 0
        while i < fl.count {
            if fl[i] == "#" { return true }
            if i >= tl.count { return false }
            if fl[i] != "+" && fl[i] != tl[i] { return false }
            i += 1
        }
        return i == tl.count
    }
}
