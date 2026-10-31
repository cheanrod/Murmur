import SwiftUI
import MurmurKit

/// Payload encodings offered in the publish editor.
enum PublishFormat: String, CaseIterable, Identifiable, Codable {
    case text, json, xml, hex, base64
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: "Text"
        case .json: "JSON"
        case .xml: "XML"
        case .hex: "Hex"
        case .base64: "Base64"
        }
    }
}

struct PublishDraft: Identifiable, Equatable, Codable {
    var id = UUID()
    var topic = ""
    var payload = ""
    var format: PublishFormat = .text
    var qos: QoS = .atMostOnce
    var retain = false
    // MQTT 5
    var contentType = ""
    var responseTopic = ""
    var correlationData = ""
    var messageExpiry = ""
    var userProperties: [UserProperty] = []
    var date = Date()

    func encodedPayload() throws -> Data {
        switch format {
        case .text, .json, .xml:
            return Data(payload.utf8)
        case .hex:
            guard let d = PayloadDecoder.data(fromHex: payload) else { throw DraftError("Payload is not valid hex") }
            return d
        case .base64:
            guard let d = Data(base64Encoded: payload.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DraftError("Payload is not valid Base64")
            }
            return d
        }
    }

    var properties: PublishProperties {
        PublishProperties(
            payloadFormatIndicator: format == .text || format == .json || format == .xml ? 1 : nil,
            messageExpiryInterval: UInt32(messageExpiry.trimmingCharacters(in: .whitespaces)),
            contentType: contentType.isEmpty ? (format == .json ? "application/json" : nil) : contentType,
            responseTopic: responseTopic.isEmpty ? nil : responseTopic,
            correlationData: correlationData.isEmpty ? nil : Data(correlationData.utf8),
            userProperties: userProperties.filter { !$0.key.isEmpty }
        )
    }
}

struct DraftError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ChartInterpolation: String, CaseIterable, Identifiable, Codable {
    case linear, stepped, smooth
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ChartTimeRange: String, CaseIterable, Identifiable, Codable {
    case all, oneMinute, fiveMinutes, fifteenMinutes, oneHour
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .oneHour: "1 hour"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .all: nil
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .oneHour: 3600
        }
    }
}

struct ChartPoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct ChartSeries: Identifiable, Equatable {
    var id = UUID()
    var topic: String
    /// JSON path into the payload; empty means the payload itself is numeric.
    var path: [String]
    var colorIndex: Int
    var interpolation: ChartInterpolation = .linear
    var timeRange: ChartTimeRange = .all
    var showPoints = false
    var points: [ChartPoint] = []

    var title: String { path.isEmpty ? topic : topic + " › " + path.joined(separator: ".") }

    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .yellow, .indigo, .mint]
    var color: Color { Self.palette[colorIndex % Self.palette.count] }

    var visiblePoints: [ChartPoint] {
        guard let s = timeRange.seconds else { return points }
        let cutoff = Date().addingTimeInterval(-s)
        return points.filter { $0.date >= cutoff }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

enum SessionStatus: Equatable {
    case connecting
    case connected
    case reconnecting(Int)
    case failed(String)
    case disconnected

    var label: String {
        switch self {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let n): "Reconnecting (attempt \(n))…"
        case .failed(let e): e
        case .disconnected: "Disconnected"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

/// State of one broker connection: the MQTT client, the topic tree and everything the UI derives from it.
@MainActor
@Observable
final class MQTTSession: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile

    // Connection
    private(set) var status: SessionStatus = .connecting
    private(set) var hasConnectedOnce = false
    private(set) var connectedSince: Date?
    private(set) var connAck: ConnAck?
    private(set) var subscriptionResults: [String: String] = [:]
    private(set) var log: [LogEntry] = []
    private(set) var clientStats = MQTTClient.Statistics()
    private(set) var messageRate: Double = 0

    // Tree
    @ObservationIgnored let tree: TopicTree
    private(set) var rows: [TopicRow] = []
    private(set) var revision = 0
    private(set) var selectionRevision = 0
    var selectedTopic: String? {
        didSet {
            guard selectedTopic != oldValue else { return }
            selectedHistoryID = nil
            compareHistoryID = nil
            selectionRevision += 1
            if let t = selectedTopic { publishDraft.topic = t }
        }
    }
    var searchText = "" { didSet { if searchText != oldValue { rebuildRows() } } }
    private(set) var viewOptions = TopicTree.ViewOptions()

    // Pause
    private(set) var isPaused = false
    @ObservationIgnored private var pausedBuffer: [MQTTMessage] = []
    private(set) var pausedCount = 0

    // Value inspection
    var selectedHistoryID: UUID?
    var compareHistoryID: UUID?
    var formatOverrides: [String: PayloadFormat] = [:]

    // Publishing
    var publishDraft = PublishDraft()
    private(set) var publishHistory: [PublishDraft] = []
    var lastPublishError: String?

    // Charts
    var charts: [ChartSeries] = []
    var showCharts = false

    @ObservationIgnored private var client: MQTTClient?
    @ObservationIgnored private var rebuildScheduled = false
    @ObservationIgnored private var lastRebuild = Date.distantPast
    @ObservationIgnored private var rateTimer: Timer?
    @ObservationIgnored private var lastRateSample = 0
    @ObservationIgnored private var maxChartPoints = UserDefaults.standard.murmurMaxChartPoints

    init(profile: ConnectionProfile) {
        self.profile = profile
        self.tree = TopicTree(historyLimit: UserDefaults.standard.murmurHistoryLimit)
        viewOptions.order = UserDefaults.standard.murmurTopicOrder
        viewOptions.autoExpand = UserDefaults.standard.murmurAutoExpand
        publishHistory = Self.loadPublishHistory(for: profile.id)
    }

    // MARK: - Connection

    func connect() {
        appendLog("Connecting to \(profile.urlDescription) as \(profile.clientID.isEmpty ? "<broker assigned>" : profile.clientID)")
        let transport: TransportConfiguration
        do {
            transport = try profile.makeTransport()
        } catch {
            status = .failed(error.localizedDescription)
            appendLog(error.localizedDescription)
            return
        }
        let client = MQTTClient(transport: transport, options: profile.makeConnectOptions(), autoReconnect: profile.autoReconnect)
        client.onStateChange = { [weak self] state in self?.handle(state) }
        client.onMessages = { [weak self] batch in self?.receive(batch) }
        client.onConnAck = { [weak self] ack in self?.connAck = ack }
        client.onLog = { [weak self] text in self?.appendLog(text) }
        self.client = client
        status = .connecting
        client.connect()

        rateTimer?.invalidate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleRate() }
        }
    }

    func disconnect() {
        client?.disconnect()
        rateTimer?.invalidate()
        rateTimer = nil
        status = .disconnected
        connectedSince = nil
    }

    /// Stop the client without changing state (used when a failed attempt is discarded).
    func cancel() {
        client?.onStateChange = nil
        client?.disconnect()
        client = nil
        rateTimer?.invalidate()
        rateTimer = nil
    }

    private func handle(_ state: MQTTClient.State) {
        switch state {
        case .connecting:
            status = .connecting
        case .connected:
            status = .connected
            hasConnectedOnce = true
            connectedSince = Date()
            subscribeAll()
        case .reconnecting(let attempt):
            status = .reconnecting(attempt)
            connectedSince = nil
        case .failed(let reason):
            status = .failed(reason)
            connectedSince = nil
            appendLog("Failed: \(reason)")
        case .disconnected:
            status = .disconnected
            connectedSince = nil
        }
    }

    /// Topic filters the broker refused in SUBACK.
    var failedSubscriptions: [String] {
        profile.subscriptions.map(\.topic).filter { subscriptionResults[$0]?.hasPrefix("Failed") == true }
    }

    private func subscribeAll() {
        let requests = profile.subscriptions.map { SubscriptionRequest(topicFilter: $0.topic, qos: $0.qos) }
        subscriptionResults = Dictionary(requests.map { ($0.topicFilter, "pending") }, uniquingKeysWith: { a, _ in a })
        client?.subscribe(requests) { [weak self] codes in
            guard let self else { return }
            for (req, code) in zip(requests, codes) {
                self.subscriptionResults[req.topicFilter] = code >= 0x80
                    ? "Failed: \(ReasonCodes.reason(code))"
                    : "Granted QoS \(code)"
            }
        }
    }

    private func sampleRate() {
        let total = tree.totalMessages + pausedCount
        messageRate = Double(max(0, total - lastRateSample))
        lastRateSample = total
        client?.statistics { [weak self] s in self?.clientStats = s }
    }

    private func appendLog(_ text: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[murmur] \(text)\n".utf8))
        #endif
        log.append(LogEntry(text: text))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: - Messages

    private func receive(_ batch: [MQTTMessage]) {
        if isPaused {
            pausedBuffer.append(contentsOf: batch)
            if pausedBuffer.count > 200_000 { pausedBuffer.removeFirst(pausedBuffer.count - 200_000) }
            pausedCount = pausedBuffer.count
            return
        }
        apply(batch)
    }

    private func apply(_ batch: [MQTTMessage]) {
        var selectedChanged = false
        for m in batch {
            tree.apply(m)
            if m.topic == selectedTopic { selectedChanged = true }
            if !charts.isEmpty { feedCharts(m) }
        }
        if selectedChanged {
            if selectedTopic.flatMap({ tree.node(for: $0) }) == nil { selectedHistoryID = nil }
            selectionRevision += 1
        }
        scheduleRebuild()
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            let buffered = pausedBuffer
            pausedBuffer = []
            pausedCount = 0
            apply(buffered)
        }
    }

    func clearTree() {
        tree.clear()
        selectedTopic = nil
        for i in charts.indices { charts[i].points.removeAll() }
        rebuildRows()
    }

    func setHistoryLimit(_ limit: Int) {
        tree.historyLimit = max(1, limit)
        selectionRevision += 1
    }

    func setMaxChartPoints(_ n: Int) { maxChartPoints = max(100, n) }

    // MARK: - Tree presentation

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        let elapsed = Date().timeIntervalSince(lastRebuild)
        let delay = max(0, 0.15 - elapsed)
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuildRows()
        }
    }

    func rebuildRows() {
        viewOptions.filter = searchText
        let newRows = tree.visibleRows(options: viewOptions)
        if newRows != rows { rows = newRows }
        lastRebuild = Date()
        revision += 1
    }

    func setOrder(_ order: TopicOrder) {
        viewOptions.order = order
        rebuildRows()
    }

    func setAutoExpand(_ value: AutoExpand) {
        viewOptions.autoExpand = value
        viewOptions.expanded.removeAll()
        viewOptions.collapsed.removeAll()
        rebuildRows()
    }

    func isExpanded(_ path: String) -> Bool {
        rows.first(where: { $0.id == path })?.isExpanded ?? false
    }

    func setExpanded(_ path: String, _ expanded: Bool) {
        if expanded {
            viewOptions.expanded.insert(path)
            viewOptions.collapsed.remove(path)
        } else {
            viewOptions.expanded.remove(path)
            viewOptions.collapsed.insert(path)
        }
        rebuildRows()
    }

    func toggleExpanded(_ path: String) {
        setExpanded(path, !isExpanded(path))
    }

    func expandAll(under path: String? = nil) {
        let nodes = path.flatMap { tree.node(for: $0) }.map { [$0] + $0.descendants } ?? tree.root.descendants
        for n in nodes where !n.orderedChildren.isEmpty {
            viewOptions.expanded.insert(n.id)
            viewOptions.collapsed.remove(n.id)
        }
        rebuildRows()
    }

    func collapseAll() {
        viewOptions.expanded.removeAll()
        viewOptions.collapsed = Set(tree.nodesByPath.values.filter { !$0.orderedChildren.isEmpty }.map(\.id))
        rebuildRows()
    }

    /// Expands all ancestors of `path` and selects it.
    func reveal(_ path: String) {
        guard let node = tree.node(for: path) else { return }
        for ancestor in node.pathNodes.dropLast() {
            viewOptions.expanded.insert(ancestor.id)
            viewOptions.collapsed.remove(ancestor.id)
        }
        selectedTopic = path
        rebuildRows()
    }

    func selectNext(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let index = selectedTopic.flatMap { t in rows.firstIndex(where: { $0.id == t }) } ?? -1
        let next = min(max(0, index + offset), rows.count - 1)
        selectedTopic = rows[next].id
    }

    /// Left arrow: collapse, or move to parent.
    func collapseOrSelectParent() {
        guard let t = selectedTopic, let node = tree.node(for: t) else { return }
        if isExpanded(t) {
            setExpanded(t, false)
        } else if let parent = node.parent, !parent.isRoot {
            selectedTopic = parent.id
        }
    }

    /// Right arrow: expand, or move to the first child.
    func expandOrSelectChild() {
        guard let t = selectedTopic, let node = tree.node(for: t), !node.orderedChildren.isEmpty else { return }
        if !isExpanded(t) {
            setExpanded(t, true)
        } else if let first = tree.sortedChildren(of: node, order: viewOptions.order).first {
            selectedTopic = first.id
        }
    }

    // MARK: - Selection helpers

    var selectedNode: TopicNode? {
        _ = selectionRevision
        return selectedTopic.flatMap { tree.node(for: $0) }
    }

    /// The message currently shown in the value panel (latest, or a picked history entry).
    var displayedMessage: MQTTMessage? {
        guard let node = selectedNode else { return nil }
        if let id = selectedHistoryID, let m = node.history.first(where: { $0.id == id }) { return m }
        return node.message
    }

    /// Message the displayed message is compared against in diff mode.
    var comparisonMessage: MQTTMessage? {
        guard let node = selectedNode, let shown = displayedMessage else { return nil }
        if let id = compareHistoryID, let m = node.history.first(where: { $0.id == id }) { return m }
        guard let idx = node.history.firstIndex(where: { $0.id == shown.id }), idx > 0 else { return nil }
        return node.history[idx - 1]
    }

    func format(for topic: String) -> PayloadFormat { formatOverrides[topic] ?? .auto }

    func decode(_ m: MQTTMessage) -> DecodedPayload {
        PayloadDecoder.decode(m.payload, format: format(for: m.topic), topic: m.topic)
    }

    // MARK: - Publishing / deleting

    func publish(_ draft: PublishDraft) {
        lastPublishError = nil
        if let e = TopicValidation.validatePublishTopic(draft.topic) {
            lastPublishError = e
            return
        }
        let payload: Data
        do {
            payload = try draft.encodedPayload()
        } catch {
            lastPublishError = error.localizedDescription
            return
        }
        client?.publish(topic: draft.topic, payload: payload, qos: draft.qos, retain: draft.retain,
                        properties: profile.mqttVersion == .v5 ? draft.properties : nil) { [weak self] error in
            if let error { self?.lastPublishError = "Publish failed: \(error.localizedDescription)" }
        }
        var entry = draft
        entry.id = UUID()
        entry.date = Date()
        publishHistory.removeAll { $0.topic == entry.topic && $0.payload == entry.payload && $0.format == entry.format }
        publishHistory.insert(entry, at: 0)
        if publishHistory.count > 50 { publishHistory.removeLast(publishHistory.count - 50) }
        Self.savePublishHistory(publishHistory, for: profile.id)
    }

    func clearPublishHistory() {
        publishHistory.removeAll()
        Self.savePublishHistory([], for: profile.id)
    }

    /// Clears a retained message by publishing an empty retained payload.
    func deleteRetained(topic: String) {
        client?.publish(topic: topic, payload: Data(), qos: .atMostOnce, retain: true)
    }

    /// Clears the topic and every retained descendant.
    func deleteRecursively(_ path: String) -> Int {
        guard let node = tree.node(for: path) else { return 0 }
        let targets = tree.valueNodes(under: node)
        for t in targets { deleteRetained(topic: t.id) }
        return targets.count
    }

    private static func historyKey(_ id: UUID) -> String { "publishHistory.\(id.uuidString)" }

    private static func loadPublishHistory(for id: UUID) -> [PublishDraft] {
        guard let data = UserDefaults.standard.data(forKey: historyKey(id)) else { return [] }
        return (try? JSONDecoder().decode([PublishDraft].self, from: data)) ?? []
    }

    private static func savePublishHistory(_ history: [PublishDraft], for id: UUID) {
        let data = try? JSONEncoder().encode(history)
        UserDefaults.standard.set(data, forKey: historyKey(id))
    }

    // MARK: - Charts

    func addChart(topic: String, path: [String]) {
        if charts.contains(where: { $0.topic == topic && $0.path == path }) {
            showCharts = true
            return
        }
        var series = ChartSeries(topic: topic, path: path, colorIndex: charts.count)
        if let node = tree.node(for: topic) {
            series.points = node.history.compactMap { m in numericValue(of: m, path: path).map { ChartPoint(date: m.received, value: $0) } }
        }
        charts.append(series)
        showCharts = true
    }

    func removeChart(_ id: UUID) {
        charts.removeAll { $0.id == id }
        if charts.isEmpty { showCharts = false }
    }

    func numericValue(of m: MQTTMessage, path: [String]) -> Double? {
        let decoded = decode(m)
        if path.isEmpty { return decoded.numericValue }
        return decoded.json?.value(at: path)?.numericValue
    }

    private func feedCharts(_ m: MQTTMessage) {
        for i in charts.indices where charts[i].topic == m.topic {
            guard let v = numericValue(of: m, path: charts[i].path) else { continue }
            charts[i].points.append(ChartPoint(date: m.received, value: v))
            if charts[i].points.count > maxChartPoints {
                charts[i].points.removeFirst(charts[i].points.count - maxChartPoints)
            }
        }
    }
}
