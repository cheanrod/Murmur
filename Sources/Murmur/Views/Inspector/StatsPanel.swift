import SwiftUI
import MurmurKit

struct StatsPanel: View {
    let session: MQTTSession
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Client") {
                LabeledGrid(items: clientItems)
            }

            group("Subscriptions") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(session.profile.subscriptions) { sub in
                        GridRow {
                            Text(sub.topic).font(.callout.monospaced())
                            let result = session.subscriptionResults[sub.topic] ?? "–"
                            Text(result)
                                .font(.callout)
                                .foregroundStyle(result.hasPrefix("Failed") ? .red : .secondary)
                        }
                    }
                }
            }

            let broker = brokerItems
            if !broker.isEmpty {
                group("Broker ($SYS)") {
                    LabeledGrid(items: broker)
                }
            }

            DisclosureGroup("Connection log (\(session.log.count))", isExpanded: $showLog) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.log.reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Formatters.time.string(from: entry.date)).foregroundStyle(.secondary)
                                Text(entry.text)
                            }
                        }
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            .font(.callout)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private var clientItems: [(String, String)] {
        _ = session.revision
        let s = session.clientStats
        var items: [(String, String)] = [
            ("Status", session.status.label),
            ("Broker", session.profile.urlDescription),
            ("MQTT version", session.profile.mqttVersion.rawValue),
            ("Client ID", session.connAck?.assignedClientID ?? session.profile.clientID),
        ]
        if let since = session.connectedSince {
            items.append(("Connected since", Formatters.dateTime.string(from: since)))
        }
        if let ack = session.connAck {
            items.append(("Session present", ack.sessionPresent ? "yes" : "no"))
            if let v = ack.maximumQoS { items.append(("Broker max QoS", "\(v)")) }
            if let v = ack.retainAvailable { items.append(("Retain available", v ? "yes" : "no")) }
            if let v = ack.serverKeepAlive { items.append(("Server keep alive", "\(v) s")) }
            if let v = ack.maximumPacketSize { items.append(("Max packet size", Formatters.bytes(Int(v)))) }
        }
        items += [
            ("Topics", Formatters.number(session.tree.topicCount)),
            ("Messages received", Formatters.number(session.tree.totalMessages)),
            ("Message rate", "\(Int(session.messageRate)) msg/s"),
            ("Payload bytes", Formatters.bytes(session.tree.totalBytes)),
            ("Bytes in / out", "\(Formatters.bytes(s.bytesReceived)) / \(Formatters.bytes(s.bytesSent))"),
            ("Packets in / out", "\(Formatters.number(s.packetsReceived)) / \(Formatters.number(s.packetsSent))"),
            ("Messages published", Formatters.number(s.messagesSent)),
        ]
        if session.isPaused { items.append(("Buffered (paused)", Formatters.number(session.pausedCount))) }
        items.append(("Murmur version", AppVersion.full == AppVersion.version ? AppVersion.display : "\(AppVersion.display) · \(AppVersion.full)"))
        return items
    }

    /// Well-known broker statistics published under $SYS (Mosquitto, EMQX, HiveMQ, VerneMQ use similar paths).
    private var brokerItems: [(String, String)] {
        _ = session.revision
        guard let sys = session.tree.node(for: "$SYS") else { return [] }
        let preferred = [
            "$SYS/broker/version", "$SYS/broker/uptime", "$SYS/broker/clients/connected",
            "$SYS/broker/clients/total", "$SYS/broker/subscriptions/count", "$SYS/broker/retained messages/count",
            "$SYS/broker/messages/received", "$SYS/broker/messages/sent",
            "$SYS/broker/load/messages/received/1min", "$SYS/broker/load/messages/sent/1min",
            "$SYS/broker/load/bytes/received/1min", "$SYS/broker/load/bytes/sent/1min",
            "$SYS/broker/heap/current", "$SYS/broker/store/messages/count",
        ]
        var items: [(String, String)] = []
        for path in preferred {
            if let node = session.tree.node(for: path), node.hasValue {
                items.append((String(path.dropFirst("$SYS/broker/".count)), node.preview))
            }
        }
        if items.isEmpty {
            for node in sys.descendants.filter(\.hasValue).prefix(25) {
                items.append((String(node.id.dropFirst(5)), node.preview))
            }
        }
        return items
    }
}
