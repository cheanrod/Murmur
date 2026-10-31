import Foundation
import Network
import MurmurKit

// A minimal local MQTT broker for trying Murmur without external infrastructure.
// It supports MQTT 3.1.1/5 basics: subscriptions with wildcards, retained messages and QoS 0–2 acks.
// With --simulate it publishes demo sensor data, JSON, Sparkplug-free binary values and $SYS stats.
//
// Usage: swift run DemoBroker [--port 1883] [--simulate]

final class Broker: @unchecked Sendable {
    final class Client {
        let conn: NWConnection
        var buffer = Data()
        var version: MQTTVersion = .v311
        var filters: [String: QoS] = [:]
        var nextID: UInt16 = 0
        var clientID = ""
        init(_ c: NWConnection) { conn = c }
    }

    let queue = DispatchQueue(label: "demo.broker")
    var clients: [ObjectIdentifier: Client] = [:]
    var retained: [String: (Data, QoS)] = [:]
    var received = 0, sent = 0
    let started = Date()

    func listen(port: UInt16) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [self] c in
            let client = Client(c)
            clients[ObjectIdentifier(client)] = client
            c.start(queue: queue)
            read(client)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { print("DemoBroker listening on mqtt://localhost:\(port)") }
            if case .failed(let e) = state { print("Listener failed: \(e)"); exit(1) }
        }
        listener.start(queue: queue)
    }

    func read(_ client: Client) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if let data { client.buffer.append(data) }
            do {
                while let p = try PacketCodec.extractPacket(from: &client.buffer, version: client.version) { handle(p, client) }
            } catch {
                print("Protocol error from \(client.clientID): \(error)")
                drop(client)
                return
            }
            if done || error != nil { drop(client); return }
            read(client)
        }
    }

    func drop(_ client: Client) {
        client.conn.cancel()
        if clients.removeValue(forKey: ObjectIdentifier(client)) != nil { print("Client disconnected: \(client.clientID)") }
    }

    func send(_ p: MQTTPacket, to client: Client) {
        client.conn.send(content: PacketCodec.encode(p, version: client.version), completion: .idempotent)
    }

    func handle(_ packet: MQTTPacket, _ client: Client) {
        switch packet {
        case .connect(let o):
            client.version = o.version
            client.clientID = o.clientID.isEmpty ? "auto-\(UUID().uuidString.prefix(6))" : o.clientID
            var props = MQTTProperties()
            if o.version == .v5 && o.clientID.isEmpty { props.add(0x12, .string(client.clientID)) }
            send(.connack(ConnAck(sessionPresent: false, code: 0, properties: props)), to: client)
            print("Client connected: \(client.clientID) (MQTT \(o.version.rawValue))")
        case .subscribe(let id, let subs):
            for s in subs { client.filters[s.topicFilter] = s.qos }
            send(.suback(id: id, codes: subs.map { $0.qos.rawValue }), to: client)
            for (topic, (payload, qos)) in retained.sorted(by: { $0.key < $1.key })
            where subs.contains(where: { TopicValidation.matches(filter: $0.topicFilter, topic: topic) }) {
                deliver(topic, payload, qos: qos, retain: true, to: client)
            }
        case .unsubscribe(let id, let filters):
            for f in filters { client.filters.removeValue(forKey: f) }
            send(.unsuback(id: id, codes: filters.map { _ in 0 }), to: client)
        case .publish(let p):
            if p.qos == .atLeastOnce, let id = p.packetID { send(.puback(id: id, reason: 0), to: client) }
            if p.qos == .exactlyOnce, let id = p.packetID { send(.pubrec(id: id, reason: 0), to: client) }
            route(p.topic, p.payload, qos: p.qos, retain: p.retain)
        case .pubrel(let id, _): send(.pubcomp(id: id, reason: 0), to: client)
        case .pubrec(let id, _): send(.pubrel(id: id, reason: 0), to: client)
        case .pingreq: send(.pingresp, to: client)
        case .disconnect: drop(client)
        default: break
        }
    }

    func route(_ topic: String, _ payload: Data, qos: QoS, retain: Bool) {
        received += 1
        if retain {
            if payload.isEmpty { retained.removeValue(forKey: topic) } else { retained[topic] = (payload, qos) }
        }
        for c in clients.values {
            let matching = c.filters.filter { TopicValidation.matches(filter: $0.key, topic: topic) }
            guard let granted = matching.values.max() else { continue }
            deliver(topic, payload, qos: min(qos, granted), retain: false, to: c)
        }
    }

    func deliver(_ topic: String, _ payload: Data, qos: QoS, retain: Bool, to c: Client) {
        sent += 1
        var id: UInt16?
        if qos != .atMostOnce {
            c.nextID = c.nextID == .max ? 1 : c.nextID + 1
            id = c.nextID
        }
        var props = MQTTProperties()
        if c.version == .v5, topic.hasSuffix("/json") { props.add(0x03, .string("application/json")) }
        send(.publish(PublishPacket(topic: topic, payload: payload, qos: qos, retain: retain, dup: false,
                                    packetID: id, properties: props)), to: c)
    }

    // MARK: Simulation

    func simulate() {
        let rooms = ["kitchen", "living-room", "bedroom", "office", "garage"]
        var t = 0.0
        func pub(_ topic: String, _ s: String, retain: Bool = false) { route(topic, Data(s.utf8), qos: .atMostOnce, retain: retain) }
        for r in rooms {
            pub("home/\(r)/light/state", Bool.random() ? "ON" : "OFF", retain: true)
            pub("home/\(r)/name", r.capitalized, retain: true)
        }
        pub("devices/gateway-01/info", #"{"model":"GW-100","firmware":"2.4.1","serial":"A1B2C3","features":["zigbee","thread","wifi"]}"#, retain: true)
        pub("$SYS/broker/version", "Murmur DemoBroker 1.0", retain: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [self] in
            t += 0.5
            for (i, r) in rooms.enumerated() {
                let temp = 20 + 3 * sin(t / 10 + Double(i)) + Double.random(in: -0.2...0.2)
                let hum = 45 + 10 * cos(t / 15 + Double(i))
                pub("home/\(r)/temperature", String(format: "%.2f", temp))
                pub("home/\(r)/humidity", String(format: "%.1f", hum))
                if Int(t * 2) % 6 == i {
                    pub("home/\(r)/sensor/json", String(format: #"{"temperature":%.2f,"humidity":%.1f,"battery":%d,"linkquality":%d,"motion":%@}"#,
                                                         temp, hum, 100 - Int(t) % 100, Int.random(in: 40...255), Bool.random() ? "true" : "false"))
                }
            }
            var power = Float(1200 + 400 * sin(t / 5)).bitPattern.bigEndian
            route("energy/meter/power/float32be", withUnsafeBytes(of: &power) { Data($0) }, qos: .atMostOnce, retain: false)
            pub("energy/meter/total_kwh", String(format: "%.3f", 1520 + t / 100))
            if Int(t) % 5 == 0 {
                pub("$SYS/broker/uptime", "\(Int(Date().timeIntervalSince(started))) seconds", retain: true)
                pub("$SYS/broker/clients/connected", "\(clients.count)", retain: true)
                pub("$SYS/broker/messages/received", "\(received)", retain: true)
                pub("$SYS/broker/messages/sent", "\(sent)", retain: true)
                pub("$SYS/broker/retained messages/count", "\(retained.count)", retain: true)
            }
        }
        timer.resume()
        simulationTimer = timer
    }

    var simulationTimer: DispatchSourceTimer?
}

let args = CommandLine.arguments
var port: UInt16 = 1883
if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = UInt16(args[i + 1]) { port = p }
let broker = Broker()
do {
    try broker.listen(port: port)
} catch {
    print("Could not listen on port \(port): \(error)")
    exit(1)
}
if args.contains("--simulate") {
    broker.queue.async { broker.simulate() }
    print("Publishing simulated data under home/#, energy/#, devices/# and $SYS/#")
}
dispatchMain()
