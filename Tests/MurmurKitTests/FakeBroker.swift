import Foundation
import Network
@testable import MurmurKit

/// A tiny in-process MQTT broker used to exercise the client end-to-end over a real TCP socket.
final class FakeBroker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake.broker")
    private let listener: NWListener
    private var connections: [ObjectIdentifier: ClientConn] = [:]
    private var retained: [String: (Data, QoS)] = [:]
    private(set) var receivedAcks: [String] = []
    var refuseCode: UInt8 = 0

    final class ClientConn {
        let conn: NWConnection
        var buffer = Data()
        var version: MQTTVersion = .v311
        var filters: [String: QoS] = [:]
        var nextID: UInt16 = 1
        init(_ c: NWConnection) { conn = c }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    cont.resume(returning: listener.port!.rawValue)
                case .failed(let e):
                    listener.stateUpdateHandler = nil
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { for c in connections.values { c.conn.cancel() } }
    }

    /// Drops all client connections abruptly (to test reconnect).
    func dropClients() {
        queue.sync { for c in connections.values { c.conn.cancel() }; connections.removeAll() }
    }

    var acks: [String] { queue.sync { receivedAcks } }

    private func accept(_ c: NWConnection) {
        let client = ClientConn(c)
        connections[ObjectIdentifier(client)] = client
        c.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: ClientConn) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { client.buffer.append(data) }
            while let packet = try? PacketCodec.extractPacket(from: &client.buffer, version: client.version) {
                self.handle(packet, client)
            }
            if done || error != nil {
                self.connections.removeValue(forKey: ObjectIdentifier(client))
                return
            }
            self.receive(client)
        }
    }

    private func send(_ p: MQTTPacket, _ client: ClientConn) {
        client.conn.send(content: PacketCodec.encode(p, version: client.version), completion: .idempotent)
    }

    private func handle(_ packet: MQTTPacket, _ client: ClientConn) {
        switch packet {
        case .connect(let o):
            client.version = o.version
            var props = MQTTProperties()
            if o.version == .v5 && o.clientID.isEmpty { props.add(0x12, .string("assigned-123")) }
            send(.connack(ConnAck(sessionPresent: false, code: refuseCode, properties: props)), client)
        case .subscribe(let id, let subs):
            for s in subs { client.filters[s.topicFilter] = s.qos }
            send(.suback(id: id, codes: subs.map { $0.qos.rawValue }), client)
            for (topic, (payload, qos)) in retained where subs.contains(where: { TopicValidation.matches(filter: $0.topicFilter, topic: topic) }) {
                deliver(topic: topic, payload: payload, qos: qos, retain: true, to: client)
            }
        case .publish(let p):
            if p.retain {
                if p.payload.isEmpty { retained.removeValue(forKey: p.topic) } else { retained[p.topic] = (p.payload, p.qos) }
            }
            if p.qos == .atLeastOnce { send(.puback(id: p.packetID!, reason: 0), client) }
            if p.qos == .exactlyOnce { send(.pubrec(id: p.packetID!, reason: 0), client) }
            for other in connections.values where other.filters.keys.contains(where: { TopicValidation.matches(filter: $0, topic: p.topic) }) {
                deliver(topic: p.topic, payload: p.payload, qos: p.qos, retain: false, to: other)
            }
        case .pubrel(let id, _):
            send(.pubcomp(id: id, reason: 0), client)
        case .puback(let id, _): receivedAcks.append("puback \(id)")
        case .pubrec(let id, _):
            receivedAcks.append("pubrec \(id)")
            send(.pubrel(id: id, reason: 0), client)
        case .pubcomp(let id, _): receivedAcks.append("pubcomp \(id)")
        case .pingreq: send(.pingresp, client)
        case .unsubscribe(let id, let filters):
            for f in filters { client.filters.removeValue(forKey: f) }
            send(.unsuback(id: id, codes: filters.map { _ in 0 }), client)
        case .disconnect: client.conn.cancel()
        default: break
        }
    }

    private func deliver(topic: String, payload: Data, qos: QoS, retain: Bool, to client: ClientConn) {
        let id: UInt16? = qos == .atMostOnce ? nil : client.nextID
        if qos != .atMostOnce { client.nextID += 1 }
        send(.publish(PublishPacket(topic: topic, payload: payload, qos: qos, retain: retain, dup: false,
                                    packetID: id, properties: MQTTProperties())), client)
    }
}
