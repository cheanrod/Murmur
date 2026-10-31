import Foundation
import Testing
@testable import MurmurKit

@MainActor
final class Recorder {
    var states: [MQTTClient.State] = []
    var messages: [MQTTMessage] = []
    var acks: [ConnAck] = []
    var subacks: [[UInt8]] = []
    var publishResults: [String] = []

    func attach(_ client: MQTTClient) {
        client.onStateChange = { [weak self] s in self?.states.append(s) }
        client.onMessages = { [weak self] m in self?.messages += m }
        client.onConnAck = { [weak self] a in self?.acks.append(a) }
    }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
@Suite(.serialized) struct ClientIntegrationTests {
    @Test(arguments: [MQTTVersion.v311, .v5])
    func publishSubscribeAllQoS(version: MQTTVersion) async throws {
        let broker = try FakeBroker()
        let port = try await broker.start()
        defer { broker.stop() }

        let client = MQTTClient(transport: TransportConfiguration(host: "127.0.0.1", port: port),
                                options: ConnectOptions(clientID: version == .v5 ? "" : "test", version: version))
        let rec = Recorder()
        rec.attach(client)
        client.connect()
        #expect(await waitUntil { rec.states.last == .connected })
        if version == .v5 { #expect(rec.acks.first?.assignedClientID == "assigned-123") }

        client.subscribe([SubscriptionRequest(topicFilter: "#", qos: .exactlyOnce)]) { rec.subacks.append($0) }
        #expect(await waitUntil { rec.subacks.count == 1 })
        #expect(rec.subacks.first == [2])

        for qos in QoS.allCases {
            client.publish(topic: "test/q\(qos.rawValue)", payload: Data("v\(qos.rawValue)".utf8), qos: qos, retain: true) { err in
                rec.publishResults.append(err == nil ? "ok\(qos.rawValue)" : "err")
            }
        }
        #expect(await waitUntil { rec.messages.count == 3 && rec.publishResults.count == 3 })
        #expect(Set(rec.messages.map(\.topic)) == ["test/q0", "test/q1", "test/q2"])
        #expect(Set(rec.publishResults) == ["ok0", "ok1", "ok2"])
        // Client must have acknowledged inbound QoS 1 and completed the QoS 2 flow.
        #expect(await waitUntil { broker.acks.contains { $0.hasPrefix("puback") } && broker.acks.contains { $0.hasPrefix("pubcomp") } })

        // Retained messages are delivered on a fresh subscription.
        let tree = TopicTree()
        let client2 = MQTTClient(transport: TransportConfiguration(host: "127.0.0.1", port: port),
                                 options: ConnectOptions(clientID: "second", version: version))
        let rec2 = Recorder()
        rec2.attach(client2)
        client2.onMessages = { msgs in rec2.messages += msgs; msgs.forEach { tree.apply($0) } }
        client2.connect()
        #expect(await waitUntil { rec2.states.last == .connected })
        client2.subscribe([SubscriptionRequest(topicFilter: "test/#", qos: .atMostOnce)])
        #expect(await waitUntil { rec2.messages.count == 3 })
        #expect(rec2.messages.allSatisfy { $0.retain })
        #expect(tree.topicCount == 3)

        // Deleting a retained topic (empty retained publish) removes it from subscribers' trees.
        client.publish(topic: "test/q1", payload: Data(), retain: true)
        #expect(await waitUntil { tree.node(for: "test/q1") == nil })

        client.disconnect()
        client2.disconnect()
        #expect(await waitUntil { rec.states.last == .disconnected })
    }

    @Test func refusedConnectionReportsReason() async throws {
        let broker = try FakeBroker()
        broker.refuseCode = 5
        let port = try await broker.start()
        defer { broker.stop() }
        let client = MQTTClient(transport: TransportConfiguration(host: "127.0.0.1", port: port),
                                options: ConnectOptions(clientID: "x"))
        let rec = Recorder()
        rec.attach(client)
        client.connect()
        #expect(await waitUntil { if case .failed = rec.states.last { return true }; return false })
        if case .failed(let reason) = rec.states.last { #expect(reason.contains("Not authorized")) }
    }

    @Test func connectionFailureWithoutBroker() async throws {
        let client = MQTTClient(transport: TransportConfiguration(host: "127.0.0.1", port: 1, connectTimeout: 3),
                                options: ConnectOptions(clientID: "x"))
        let rec = Recorder()
        rec.attach(client)
        client.connect()
        #expect(await waitUntil(6) { if case .failed = rec.states.last { return true }; return false })
    }

    @Test func reconnectsAfterDrop() async throws {
        let broker = try FakeBroker()
        let port = try await broker.start()
        defer { broker.stop() }
        let client = MQTTClient(transport: TransportConfiguration(host: "127.0.0.1", port: port),
                                options: ConnectOptions(clientID: "r"), autoReconnect: true)
        let rec = Recorder()
        rec.attach(client)
        client.connect()
        #expect(await waitUntil { rec.states.last == .connected })
        broker.dropClients()
        #expect(await waitUntil { rec.states.contains { if case .reconnecting = $0 { return true }; return false } })
        #expect(await waitUntil(8) { rec.states.last == .connected })
        client.disconnect()
    }
}
