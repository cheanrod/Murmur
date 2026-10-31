import Foundation
import Network

/// An MQTT 3.1.1 / 5.0 client built on Network.framework.
///
/// All protocol work happens on a private serial queue. Callbacks are delivered on the main queue.
/// Incoming messages are batched (every `deliveryInterval`) so high-throughput brokers don't flood the UI.
public final class MQTTClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(String)

        public var isConnected: Bool { self == .connected }
    }

    public struct Statistics: Sendable {
        public var bytesReceived = 0
        public var bytesSent = 0
        public var packetsReceived = 0
        public var packetsSent = 0
        public var messagesReceived = 0
        public var messagesSent = 0
        public init() {}
    }

    // MARK: Public callbacks (main queue)

    public var onStateChange: ((State) -> Void)?
    public var onMessages: (([MQTTMessage]) -> Void)?
    public var onConnAck: ((ConnAck) -> Void)?
    public var onLog: ((String) -> Void)?

    public let transport: TransportConfiguration
    public private(set) var options: ConnectOptions
    public var autoReconnect: Bool
    public var deliveryInterval: TimeInterval = 0.05

    // MARK: Private state (queue only)

    private let queue = DispatchQueue(label: "murmur.mqtt.client", qos: .userInitiated)
    private var connection: NWConnection?
    private var generation = 0
    private var buffer = Data()
    private var state: State = .disconnected
    private var userRequestedDisconnect = false
    private var everConnected = false
    private var reconnectAttempt = 0
    private var keepAliveTimer: DispatchSourceTimer?
    private var connackTimer: DispatchWorkItem?
    private var awaitingPingResponse = false
    private var lastPacketSent = Date()
    private var nextPacketID: UInt16 = 0
    private var pendingSubscribes: [UInt16: ([UInt8]) -> Void] = [:]
    private var pendingUnsubscribes: [UInt16: ([UInt8]) -> Void] = [:]
    private var outboundInflight: [UInt16: (Error?) -> Void] = [:]
    private var inboundQoS2: Set<UInt16> = []
    private var inboundTopicAliases: [UInt16: String] = [:]
    private var pendingDelivery: [MQTTMessage] = []
    private var deliveryScheduled = false
    private var stats = Statistics()

    public init(transport: TransportConfiguration, options: ConnectOptions, autoReconnect: Bool = true) {
        self.transport = transport
        self.options = options
        self.autoReconnect = autoReconnect
    }

    deinit {
        connection?.cancel()
        keepAliveTimer?.cancel()
    }

    private var version: MQTTVersion { options.version }

    // MARK: - Public API

    public func connect() {
        queue.async { [self] in
            userRequestedDisconnect = false
            everConnected = false
            reconnectAttempt = 0
            startConnection(isReconnect: false)
        }
    }

    public func disconnect() {
        queue.async { [self] in
            userRequestedDisconnect = true
            if let c = connection, state == .connected {
                let data = PacketCodec.encode(.disconnect(reason: 0, reasonString: nil), version: version)
                send(data, on: c) { c.cancel() }
            } else {
                connection?.cancel()
            }
            teardown()
            setState(.disconnected)
        }
    }

    public func statistics(_ completion: @escaping (Statistics) -> Void) {
        queue.async { [self] in
            let s = stats
            DispatchQueue.main.async { completion(s) }
        }
    }

    public func subscribe(_ subscriptions: [SubscriptionRequest], completion: (([UInt8]) -> Void)? = nil) {
        guard !subscriptions.isEmpty else { return }
        queue.async { [self] in
            guard state == .connected else { return }
            let id = allocatePacketID()
            if let completion { pendingSubscribes[id] = completion }
            log("SUBSCRIBE \(subscriptions.map { "\($0.topicFilter) (QoS \($0.qos.rawValue))" }.joined(separator: ", "))")
            sendPacket(.subscribe(id: id, subscriptions))
        }
    }

    public func unsubscribe(_ filters: [String], completion: (([UInt8]) -> Void)? = nil) {
        guard !filters.isEmpty else { return }
        queue.async { [self] in
            guard state == .connected else { return }
            let id = allocatePacketID()
            if let completion { pendingUnsubscribes[id] = completion }
            sendPacket(.unsubscribe(id: id, filters))
        }
    }

    public func publish(
        topic: String, payload: Data, qos: QoS = .atMostOnce, retain: Bool = false,
        properties: PublishProperties? = nil, completion: ((Error?) -> Void)? = nil
    ) {
        queue.async { [self] in
            guard state == .connected else {
                if let completion { DispatchQueue.main.async { completion(MQTTError.notConnected) } }
                return
            }
            var packetID: UInt16?
            if qos != .atMostOnce {
                let id = allocatePacketID()
                packetID = id
                outboundInflight[id] = { error in
                    if let completion { DispatchQueue.main.async { completion(error) } }
                }
            }
            let props = version == .v5 ? (properties?.mqttProperties ?? MQTTProperties()) : MQTTProperties()
            stats.messagesSent += 1
            sendPacket(.publish(PublishPacket(
                topic: topic, payload: payload, qos: qos, retain: retain, dup: false,
                packetID: packetID, properties: props)))
            if qos == .atMostOnce, let completion {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: - Connection lifecycle

    private func startConnection(isReconnect: Bool) {
        teardown()
        generation += 1
        let gen = generation
        buffer = Data()
        setState(isReconnect ? .reconnecting(attempt: reconnectAttempt) : .connecting)
        log("Connecting to \(transport.urlDescription)")

        let conn: NWConnection
        do {
            conn = try transport.makeConnection(queue: queue)
        } catch {
            fail(error.localizedDescription, generation: gen)
            return
        }
        connection = conn
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self, gen == self.generation else { return }
            switch newState {
            case .ready:
                self.log("Transport ready, sending CONNECT")
                self.receive(on: conn, generation: gen)
                self.sendPacket(.connect(self.options))
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, gen == self.generation, self.state != .connected else { return }
                    self.fail("Timed out waiting for CONNACK", generation: gen)
                }
                self.connackTimer = timer
                self.queue.asyncAfter(deadline: .now() + self.transport.connectTimeout, execute: timer)
            case .waiting(let error):
                self.fail(self.describe(error), generation: gen)
            case .failed(let error):
                self.fail(self.describe(error), generation: gen)
            case .cancelled:
                if !self.userRequestedDisconnect { self.fail("Connection closed", generation: gen) }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func describe(_ error: NWError) -> String {
        let target = "\(transport.host):\(transport.port)"
        switch error {
        case .tls(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "TLS error with \(target): \(message)"
        case .posix(let code):
            switch code {
            case .ETIMEDOUT:
                return "Could not reach \(target): the connection timed out. The broker may be down or overloaded, or a firewall may be blocking the port."
            case .ECONNREFUSED:
                return "\(target) refused the connection. Nothing is listening on that port; check the port and protocol."
            case .ENETUNREACH, .EHOSTUNREACH:
                return "\(target) is unreachable. Check your network connection."
            case .ECONNRESET:
                return "\(target) reset the connection."
            default:
                return "\(target): \(String(cString: strerror(code.rawValue)))"
            }
        case .dns(let code):
            return "Could not resolve host \(transport.host) (DNS error \(code))."
        default:
            return "\(target): \(error.debugDescription)"
        }
    }

    private var closedMessage: String {
        if state == .connected {
            return "\(transport.host) closed the connection."
        }
        return "\(transport.host) closed the connection before accepting it (no CONNACK). The broker may be rejecting this client or address, or may need a different MQTT version, credentials or TLS setting."
    }

    private func teardown() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        connackTimer?.cancel()
        connackTimer = nil
        awaitingPingResponse = false
        if let c = connection {
            c.stateUpdateHandler = nil
            if !userRequestedDisconnect { c.cancel() }
        }
        connection = nil
        pendingSubscribes.removeAll()
        pendingUnsubscribes.removeAll()
        for (_, completion) in outboundInflight { completion(MQTTError.notConnected) }
        outboundInflight.removeAll()
        inboundQoS2.removeAll()
        inboundTopicAliases.removeAll()
    }

    private func fail(_ reason: String, generation gen: Int) {
        guard gen == generation else { return }
        generation += 1 // invalidate callbacks of the failed connection
        log("Connection lost: \(reason)")
        teardown()
        flushDelivery()
        guard !userRequestedDisconnect else {
            setState(.disconnected)
            return
        }
        if autoReconnect && everConnected {
            reconnectAttempt += 1
            let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))) / 2)
            setState(.reconnecting(attempt: reconnectAttempt))
            let expected = generation
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.userRequestedDisconnect, expected == self.generation else { return }
                self.startConnection(isReconnect: true)
            }
        } else {
            setState(.failed(reason))
        }
    }

    // MARK: - IO

    private func receive(on conn: NWConnection, generation gen: Int) {
        let handler: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, context, isComplete, error in
            guard let self, gen == self.generation else { return }
            if let data, !data.isEmpty {
                self.stats.bytesReceived += data.count
                self.buffer.append(data)
                self.processBuffer(generation: gen)
                guard gen == self.generation else { return }
            }
            if let error {
                self.fail(self.describe(error), generation: gen)
                return
            }
            if self.transport.useWebSocket {
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   meta.opcode == .close {
                    self.fail(self.closedMessage, generation: gen)
                    return
                }
            } else if isComplete {
                self.fail(self.closedMessage, generation: gen)
                return
            }
            self.receive(on: conn, generation: gen)
        }
        if transport.useWebSocket {
            conn.receiveMessage(completion: handler)
        } else {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20, completion: handler)
        }
    }

    private func processBuffer(generation gen: Int) {
        do {
            while gen == generation, let packet = try PacketCodec.extractPacket(from: &buffer, version: version) {
                stats.packetsReceived += 1
                handle(packet, generation: gen)
            }
        } catch {
            fail(error.localizedDescription, generation: gen)
        }
    }

    private func sendPacket(_ packet: MQTTPacket) {
        guard let c = connection else { return }
        let data = PacketCodec.encode(packet, version: version)
        stats.packetsSent += 1
        send(data, on: c, completion: nil)
    }

    private func send(_ data: Data, on conn: NWConnection, completion: (() -> Void)?) {
        stats.bytesSent += data.count
        lastPacketSent = Date()
        let gen = generation
        let done: (NWError?) -> Void = { [weak self] error in
            completion?()
            if let error, let self { self.fail(self.describe(error), generation: gen) }
        }
        if transport.useWebSocket {
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "mqtt", metadata: [meta])
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed(done))
        } else {
            conn.send(content: data, completion: .contentProcessed(done))
        }
    }

    // MARK: - Packet handling

    private func handle(_ packet: MQTTPacket, generation gen: Int) {
        switch packet {
        case .connack(let ack):
            connackTimer?.cancel()
            DispatchQueue.main.async { [onConnAck] in onConnAck?(ack) }
            guard ack.code == 0 else {
                let reason = ack.reasonString ?? ReasonCodes.connack(ack.code, version: version)
                everConnected = false // don't auto-reconnect on refusal
                fail("Connection refused: \(reason)", generation: gen)
                return
            }
            if let assigned = ack.assignedClientID { log("Broker assigned client id \(assigned)") }
            everConnected = true
            reconnectAttempt = 0
            setState(.connected)
            startKeepAlive(serverOverride: ack.serverKeepAlive)

        case .publish(var p):
            if version == .v5, let alias = p.properties.u16(0x23) {
                if p.topic.isEmpty {
                    guard let t = inboundTopicAliases[alias] else {
                        fail("Unknown topic alias \(alias)", generation: gen)
                        return
                    }
                    p.topic = t
                } else {
                    inboundTopicAliases[alias] = p.topic
                }
            }
            switch p.qos {
            case .atMostOnce:
                deliver(p)
            case .atLeastOnce:
                deliver(p)
                if let id = p.packetID { sendPacket(.puback(id: id, reason: 0)) }
            case .exactlyOnce:
                guard let id = p.packetID else { return }
                if !inboundQoS2.contains(id) {
                    inboundQoS2.insert(id)
                    deliver(p)
                }
                sendPacket(.pubrec(id: id, reason: 0))
            }

        case .puback(let id, let reason):
            let completion = outboundInflight.removeValue(forKey: id)
            completion?(reason >= 0x80 ? MQTTError.protocolViolation(ReasonCodes.reason(reason)) : nil)

        case .pubrec(let id, let reason):
            if reason >= 0x80 {
                outboundInflight.removeValue(forKey: id)?(MQTTError.protocolViolation(ReasonCodes.reason(reason)))
            } else {
                sendPacket(.pubrel(id: id, reason: 0))
            }

        case .pubrel(let id, _):
            inboundQoS2.remove(id)
            sendPacket(.pubcomp(id: id, reason: 0))

        case .pubcomp(let id, _):
            outboundInflight.removeValue(forKey: id)?(nil)

        case .suback(let id, let codes):
            log("SUBACK \(codes.map { $0 >= 0x80 ? "failure(\(ReasonCodes.reason($0)))" : "QoS \($0)" }.joined(separator: ", "))")
            if let completion = pendingSubscribes.removeValue(forKey: id) {
                DispatchQueue.main.async { completion(codes) }
            }

        case .unsuback(let id, let codes):
            if let completion = pendingUnsubscribes.removeValue(forKey: id) {
                DispatchQueue.main.async { completion(codes) }
            }

        case .pingresp:
            awaitingPingResponse = false

        case .disconnect(let reason, let reasonString):
            fail("Broker disconnected: \(reasonString ?? ReasonCodes.reason(reason))", generation: gen)

        case .pingreq:
            sendPacket(.pingresp)

        case .connect, .subscribe, .unsubscribe, .auth:
            fail("Unexpected packet from broker", generation: gen)
        }
    }

    private func deliver(_ p: PublishPacket) {
        let props: PublishProperties? = version == .v5 && !p.properties.items.isEmpty ? PublishProperties(p.properties) : nil
        stats.messagesReceived += 1
        pendingDelivery.append(MQTTMessage(topic: p.topic, payload: p.payload, qos: p.qos, retain: p.retain, properties: props))
        if !deliveryScheduled {
            deliveryScheduled = true
            queue.asyncAfter(deadline: .now() + deliveryInterval) { [weak self] in self?.flushDelivery() }
        }
    }

    private func flushDelivery() {
        deliveryScheduled = false
        guard !pendingDelivery.isEmpty else { return }
        let batch = pendingDelivery
        pendingDelivery = []
        DispatchQueue.main.async { [weak self] in self?.onMessages?(batch) }
    }

    private func startKeepAlive(serverOverride: UInt16?) {
        let interval = TimeInterval(serverOverride ?? options.keepAlive)
        guard interval > 0 else { return }
        let gen = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let tick = max(1.0, interval * 0.75)
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self, gen == self.generation else { return }
            if self.awaitingPingResponse {
                self.fail("Keep-alive timeout (no PINGRESP)", generation: gen)
                return
            }
            self.awaitingPingResponse = true
            self.sendPacket(.pingreq)
        }
        keepAliveTimer = timer
        timer.resume()
    }

    private func allocatePacketID() -> UInt16 {
        repeat {
            nextPacketID = nextPacketID == UInt16.max ? 1 : nextPacketID + 1
        } while outboundInflight[nextPacketID] != nil || pendingSubscribes[nextPacketID] != nil
            || pendingUnsubscribes[nextPacketID] != nil
        return nextPacketID
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(newState) }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }
}
