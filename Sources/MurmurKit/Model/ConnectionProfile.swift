import Foundation
import Security

public struct SubscriptionConfig: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var topic: String
    public var qos: QoS

    public init(topic: String, qos: QoS = .atMostOnce) {
        self.topic = topic
        self.qos = qos
    }
}

/// A file (certificate etc.) embedded into a profile so it keeps working if the original is moved.
public struct EmbeddedFile: Codable, Hashable, Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum TransportProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    case mqtt, websocket
    public var id: String { rawValue }
    public var label: String { self == .mqtt ? "mqtt://" : "ws://" }
}

public struct ConnectionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var host: String
    public var port: UInt16
    public var transport: TransportProtocol
    public var basePath: String
    public var useTLS: Bool
    public var validateCertificate: Bool
    public var username: String
    public var password: String
    public var clientID: String
    public var mqttVersion: MQTTVersion
    public var cleanSession: Bool
    public var keepAlive: UInt16
    public var sessionExpiry: UInt32
    public var autoReconnect: Bool
    public var subscriptions: [SubscriptionConfig]
    public var caCertificate: EmbeddedFile?
    public var clientCertificate: EmbeddedFile?
    public var clientCertificatePassword: String
    public var alpn: String
    public var lastWillEnabled: Bool
    public var lastWill: LastWill

    public init(
        name: String = "New Connection",
        host: String = "",
        port: UInt16 = 1883,
        transport: TransportProtocol = .mqtt,
        basePath: String = "/mqtt",
        useTLS: Bool = false,
        validateCertificate: Bool = true,
        username: String = "",
        password: String = "",
        clientID: String = ConnectionProfile.randomClientID(),
        mqttVersion: MQTTVersion = .v311,
        cleanSession: Bool = true,
        keepAlive: UInt16 = 60,
        sessionExpiry: UInt32 = 0,
        autoReconnect: Bool = true,
        subscriptions: [SubscriptionConfig] = ConnectionProfile.defaultSubscriptions
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.transport = transport
        self.basePath = basePath
        self.useTLS = useTLS
        self.validateCertificate = validateCertificate
        self.username = username
        self.password = password
        self.clientID = clientID
        self.mqttVersion = mqttVersion
        self.cleanSession = cleanSession
        self.keepAlive = keepAlive
        self.sessionExpiry = sessionExpiry
        self.autoReconnect = autoReconnect
        self.subscriptions = subscriptions
        self.clientCertificatePassword = ""
        self.alpn = ""
        self.lastWillEnabled = false
        self.lastWill = LastWill()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, transport, basePath, useTLS, validateCertificate, username, password, clientID
        case mqttVersion, cleanSession, keepAlive, sessionExpiry, autoReconnect, subscriptions, caCertificate
        case clientCertificate, clientCertificatePassword, alpn, lastWillEnabled, lastWill
    }

    /// Secrets (`password`, `clientCertificatePassword`) are deliberately not encoded; `ProfileStore` keeps them in the Keychain.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(transport, forKey: .transport)
        try c.encode(basePath, forKey: .basePath)
        try c.encode(useTLS, forKey: .useTLS)
        try c.encode(validateCertificate, forKey: .validateCertificate)
        try c.encode(username, forKey: .username)
        try c.encode(clientID, forKey: .clientID)
        try c.encode(mqttVersion, forKey: .mqttVersion)
        try c.encode(cleanSession, forKey: .cleanSession)
        try c.encode(keepAlive, forKey: .keepAlive)
        try c.encode(sessionExpiry, forKey: .sessionExpiry)
        try c.encode(autoReconnect, forKey: .autoReconnect)
        try c.encode(subscriptions, forKey: .subscriptions)
        try c.encodeIfPresent(caCertificate, forKey: .caCertificate)
        try c.encodeIfPresent(clientCertificate, forKey: .clientCertificate)
        try c.encode(alpn, forKey: .alpn)
        try c.encode(lastWillEnabled, forKey: .lastWillEnabled)
        try c.encode(lastWill, forKey: .lastWill)
    }

    // Tolerant decoding so profiles survive schema additions.
    // `password` / `clientCertificatePassword` are still read so plaintext files from older versions migrate to the Keychain.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConnectionProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        transport = try c.decodeIfPresent(TransportProtocol.self, forKey: .transport) ?? d.transport
        basePath = try c.decodeIfPresent(String.self, forKey: .basePath) ?? d.basePath
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? d.useTLS
        validateCertificate = try c.decodeIfPresent(Bool.self, forKey: .validateCertificate) ?? d.validateCertificate
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? d.clientID
        mqttVersion = try c.decodeIfPresent(MQTTVersion.self, forKey: .mqttVersion) ?? d.mqttVersion
        cleanSession = try c.decodeIfPresent(Bool.self, forKey: .cleanSession) ?? d.cleanSession
        keepAlive = try c.decodeIfPresent(UInt16.self, forKey: .keepAlive) ?? d.keepAlive
        sessionExpiry = try c.decodeIfPresent(UInt32.self, forKey: .sessionExpiry) ?? 0
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        subscriptions = try c.decodeIfPresent([SubscriptionConfig].self, forKey: .subscriptions) ?? d.subscriptions
        caCertificate = try c.decodeIfPresent(EmbeddedFile.self, forKey: .caCertificate)
        clientCertificate = try c.decodeIfPresent(EmbeddedFile.self, forKey: .clientCertificate)
        clientCertificatePassword = try c.decodeIfPresent(String.self, forKey: .clientCertificatePassword) ?? ""
        alpn = try c.decodeIfPresent(String.self, forKey: .alpn) ?? ""
        lastWillEnabled = try c.decodeIfPresent(Bool.self, forKey: .lastWillEnabled) ?? false
        lastWill = try c.decodeIfPresent(LastWill.self, forKey: .lastWill) ?? LastWill()
    }

    public static let defaultSubscriptions = [
        SubscriptionConfig(topic: "#", qos: .atMostOnce),
        SubscriptionConfig(topic: "$SYS/#", qos: .atMostOnce),
    ]

    public static func randomClientID() -> String {
        "murmur_" + String(UUID().uuidString.prefix(8)).lowercased()
    }

    public var urlDescription: String {
        let scheme: String = switch (transport, useTLS) {
        case (.mqtt, false): "mqtt"
        case (.mqtt, true): "mqtts"
        case (.websocket, false): "ws"
        case (.websocket, true): "wss"
        }
        let path = transport == .websocket ? (basePath.hasPrefix("/") ? basePath : "/" + basePath) : ""
        return "\(scheme)://\(host):\(port)\(path)"
    }

    /// Returns a list of problems that prevent connecting.
    public var validationErrors: [String] {
        var errors: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Host is required") }
        if port == 0 { errors.append("Port must be between 1 and 65535") }
        if subscriptions.isEmpty { errors.append("Add at least one subscription") }
        for s in subscriptions {
            if let e = TopicValidation.validateFilter(s.topic) { errors.append("Subscription '\(s.topic)': \(e)") }
        }
        if lastWillEnabled, let e = TopicValidation.validatePublishTopic(lastWill.topic) { errors.append("Last will: \(e)") }
        return errors
    }

    public func makeTransport() throws -> TransportConfiguration {
        var anchors: [SecCertificate] = []
        if let ca = caCertificate { anchors = try CertificateLoader.certificates(from: ca.data) }
        var identity: SecIdentity?
        if let client = clientCertificate {
            identity = try CertificateLoader.identity(fromPKCS12: client.data, password: clientCertificatePassword)
        }
        return TransportConfiguration(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            useTLS: useTLS,
            useWebSocket: transport == .websocket,
            webSocketPath: basePath,
            validateCertificate: validateCertificate,
            caCertificates: anchors,
            clientIdentity: identity,
            alpnProtocols: alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )
    }

    public func makeConnectOptions() -> ConnectOptions {
        ConnectOptions(
            clientID: clientID.isEmpty && mqttVersion == .v311 ? ConnectionProfile.randomClientID() : clientID,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            cleanSession: cleanSession,
            keepAlive: keepAlive,
            will: lastWillEnabled ? lastWill : nil,
            version: mqttVersion,
            sessionExpiry: sessionExpiry
        )
    }

    public static let samples: [ConnectionProfile] = [
        ConnectionProfile(name: "test.mosquitto.org", host: "test.mosquitto.org", port: 1883),
        ConnectionProfile(name: "broker.hivemq.com", host: "broker.hivemq.com", port: 1883),
        ConnectionProfile(name: "localhost", host: "localhost", port: 1883),
    ]
}

/// Persists connection profiles as JSON in Application Support (file mode 0600).
/// Secrets live in a `CredentialStore` (the Keychain by default), never in the JSON file.
public final class ProfileStore {
    public let url: URL
    public let credentials: CredentialStore
    /// Problems talking to the credential store during the last load/save (shown to the user).
    public private(set) var credentialErrors: [String] = []

    /// Secrets as last read from / written to the credential store, to avoid redundant keychain writes.
    private var knownSecrets: [String: String] = [:]

    public init(directory: URL? = nil, credentials: CredentialStore = KeychainCredentialStore()) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        url = base.appendingPathComponent("connections.json")
        self.credentials = credentials
    }

    static func passwordAccount(_ id: UUID) -> String { "\(id.uuidString).password" }
    static func certificatePasswordAccount(_ id: UUID) -> String { "\(id.uuidString).certificatePassword" }

    public func load() -> [ConnectionProfile] {
        credentialErrors = []
        guard let data = try? Data(contentsOf: url),
              var profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else {
            return ConnectionProfile.samples
        }
        var migrated = false
        for i in profiles.indices {
            let id = profiles[i].id
            for (account, keyPath) in Self.secretFields(id) {
                let legacy = profiles[i][keyPath: keyPath]
                if !legacy.isEmpty {
                    // Plaintext secret from an older version: move it into the credential store.
                    migrated = true
                    continue
                }
                do {
                    let stored = try credentials.secret(for: account) ?? ""
                    profiles[i][keyPath: keyPath] = stored
                    knownSecrets[account] = stored
                } catch {
                    credentialErrors.append(error.localizedDescription)
                }
            }
        }
        if migrated {
            try? save(profiles) // writes secrets to the keychain and rewrites the JSON without them
        }
        return profiles
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        credentialErrors = []
        var current: [String: String] = [:]
        for p in profiles {
            for (account, keyPath) in Self.secretFields(p.id) {
                let value = p[keyPath: keyPath]
                current[account] = value
                guard knownSecrets[account, default: ""] != value else { continue }
                do {
                    try credentials.setSecret(value, for: account)
                    knownSecrets[account] = value
                } catch {
                    credentialErrors.append(error.localizedDescription)
                }
            }
        }
        // Remove secrets of deleted profiles.
        for account in knownSecrets.keys where current[account] == nil {
            do {
                try credentials.setSecret(nil, for: account)
                knownSecrets.removeValue(forKey: account)
            } catch {
                credentialErrors.append(error.localizedDescription)
            }
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func secretFields(_ id: UUID) -> [(String, WritableKeyPath<ConnectionProfile, String>)] {
        [(passwordAccount(id), \.password), (certificatePasswordAccount(id), \.clientCertificatePassword)]
    }
}
