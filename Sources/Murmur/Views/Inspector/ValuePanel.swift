import SwiftUI
import Charts
import UniformTypeIdentifiers
import MurmurKit

enum ValueMode: String, CaseIterable, Identifiable {
    case formatted, raw, diff
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ValuePanel: View {
    @Bindable var session: MQTTSession
    @AppStorage("valueMode") private var mode: ValueMode = .formatted
    @AppStorage(SettingsKey.timestampStyle) private var timestampStyle: TimestampStyle = .relative
    @State private var exporting = false

    var body: some View {
        if let node = session.selectedNode {
            if let message = session.displayedMessage {
                content(node: node, message: message)
            } else {
                Text(node.orderedChildren.isEmpty ? "No value" : "This topic has no value of its own, only subtopics.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Select a topic to inspect its value.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(node: TopicNode, message: MQTTMessage) -> some View {
        let decoded = session.decode(message)
        VStack(alignment: .leading, spacing: 8) {
            header(node: node, message: message)

            HStack(spacing: 6) {
                Picker("Mode", selection: $mode) {
                    ForEach(ValueMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                Spacer()

                Menu {
                    Picker("Decode as", selection: Binding(
                        get: { session.format(for: node.id) },
                        set: { session.formatOverrides[node.id] = $0 == .auto ? nil : $0 }
                    )) {
                        ForEach(PayloadFormat.textual) { Text($0.label).tag($0) }
                        Divider()
                        ForEach(PayloadFormat.binaryNumbers) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(decoded.format.label, systemImage: "wand.and.rays")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose how the payload is decoded")

                Button { Pasteboard.copy(decoded.text) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy value")
                Button { exporting = true } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save payload to a file")
                if decoded.numericValue != nil {
                    Button { session.addChart(topic: node.id, path: []) } label: { Image(systemName: "chart.xyaxis.line") }
                        .help("Plot this value")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if let error = decoded.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Group {
                switch mode {
                case .formatted: formatted(decoded, topic: node.id)
                case .raw: CodeText(text: rawText(message))
                case .diff: diff(current: message, decoded: decoded)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let props = message.properties, !props.isEmpty {
                PropertiesView(properties: props)
            }
        }
        .fileExporter(isPresented: $exporting, document: PayloadDocument(data: message.payload),
                      contentType: .data, defaultFilename: suggestedFilename(node: node, decoded: decoded)) { _ in }
    }

    @ViewBuilder
    private func header(node: TopicNode, message: MQTTMessage) -> some View {
        HStack(spacing: 6) {
            Badge(text: "QoS \(message.qos.rawValue)", color: .blue)
            if message.retain { Badge(text: "retained", color: .purple) }
            if session.selectedHistoryID != nil {
                Badge(text: "history", color: .orange)
                Button("Show latest") { session.selectedHistoryID = nil }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
            Spacer()
            Text(Formatters.bytes(message.payload.count))
                .foregroundStyle(.secondary)
            timestamp(message.received)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func timestamp(_ date: Date) -> some View {
        switch timestampStyle {
        case .relative:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(date, format: .relative(presentation: .named))
            }
            .help(Formatters.dateTime.string(from: date))
        case .absolute:
            Text(Formatters.dateTime.string(from: date) + "." + String(format: "%03d", Int(date.timeIntervalSince1970 * 1000) % 1000))
        }
    }

    @ViewBuilder
    private func formatted(_ decoded: DecodedPayload, topic: String) -> some View {
        if decoded.kind == .empty {
            Text("(empty payload)").foregroundStyle(.secondary)
        } else if let json = decoded.json, json.isContainer {
            JSONTreeView(value: json) { path in session.addChart(topic: topic, path: path) }
        } else {
            CodeText(text: decoded.text)
        }
    }

    @ViewBuilder
    private func diff(current: MQTTMessage, decoded: DecodedPayload) -> some View {
        if let previous = session.comparisonMessage {
            let old = session.decode(previous).text
            VStack(alignment: .leading, spacing: 4) {
                Text("Compared with message from \(Formatters.time.string(from: previous.received))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if old == decoded.text {
                    Text("No changes").foregroundStyle(.secondary)
                }
                DiffView(lines: TextDiff.diff(old: String(old.prefix(100_000)), new: String(decoded.text.prefix(100_000))))
            }
        } else {
            Text("No earlier message to compare with.").foregroundStyle(.secondary)
        }
    }

    private func rawText(_ m: MQTTMessage) -> String {
        if let s = String(data: m.payload, encoding: .utf8) { return s }
        return PayloadDecoder.hexDump(m.payload)
    }

    private func suggestedFilename(node: TopicNode, decoded: DecodedPayload) -> String {
        let base = node.id.replacingOccurrences(of: "/", with: "_")
        switch decoded.kind {
        case .json, .sparkplug: return base + ".json"
        case .text: return base + ".txt"
        default: return base + ".bin"
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

/// Selectable monospaced text with a size cap so huge payloads don't stall layout.
struct CodeText: View {
    let text: String
    var limit = 200_000

    var body: some View {
        let shown = text.count > limit ? String(text.prefix(limit)) + "\n… (truncated, \(text.count - limit) more characters)" : text
        ScrollView(.horizontal) {
            Text(shown.isEmpty ? " " : shown)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .frame(maxHeight: 420)
    }
}

struct PayloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - JSON tree

struct JSONTreeView: View {
    let value: JSONValue
    let onChart: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            JSONNodeView(key: nil, isIndex: false, value: value, path: [], depth: 0, onChart: onChart)
        }
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
    }
}

private struct JSONNodeView: View {
    let key: String?
    let isIndex: Bool
    let value: JSONValue
    let path: [String]
    let depth: Int
    let onChart: ([String]) -> Void
    @State private var expanded: Bool

    init(key: String?, isIndex: Bool, value: JSONValue, path: [String], depth: Int, onChart: @escaping ([String]) -> Void) {
        self.key = key
        self.isIndex = isIndex
        self.value = value
        self.path = path
        self.depth = depth
        self.onChart = onChart
        _expanded = State(initialValue: depth < 4)
    }

    var body: some View {
        if value.isContainer {
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        keyLabel
                        Text(summary).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    let children = value.children
                    let childIsIndex: Bool = { if case .array = value { return true }; return false }()
                    ForEach(children.indices.prefix(1000), id: \.self) { i in
                        JSONNodeView(key: children[i].key, isIndex: childIsIndex, value: children[i].value,
                                     path: path + [children[i].key], depth: depth + 1, onChart: onChart)
                    }
                    if children.count > 1000 {
                        Text("… \(children.count - 1000) more").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, depth == 0 ? 0 : 12)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Color.clear.frame(width: 10, height: 1)
                keyLabel
                Text(leafText)
                    .foregroundStyle(leafColor)
                    .fixedSize(horizontal: false, vertical: true)
                if isPlottable {
                    Button { onChart(path) } label: { Image(systemName: "chart.xyaxis.line").font(.caption) }
                        .buttonStyle(.borderless)
                        .help("Plot \(path.joined(separator: "."))")
                }
            }
            .padding(.leading, depth == 0 ? 0 : 12)
        }
    }

    @ViewBuilder private var keyLabel: some View {
        if let key {
            Text(isArrayIndex ? "[\(key)]" : key + ":")
                .foregroundStyle(isArrayIndex ? Color.secondary : Color.accentColor)
        }
    }

    private var isArrayIndex: Bool { isIndex }

    private var isPlottable: Bool {
        switch value {
        case .number, .bool: true
        default: false
        }
    }

    private var summary: String {
        switch value {
        case .array(let a): "[\(a.count)]"
        case .object(let o): "{\(o.count)}"
        default: ""
        }
    }

    private var leafText: String {
        switch value {
        case .string(let s): JSONValue.quote(s)
        default: value.serialized(pretty: false)
        }
    }

    private var leafColor: Color {
        switch value {
        case .string: .green
        case .number: .orange
        case .bool: .purple
        case .null: .secondary
        default: .primary
        }
    }
}

// MARK: - Diff

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.prefix(5000)) { line in
                    HStack(spacing: 6) {
                        Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                            .frame(width: 10)
                            .foregroundStyle(color(line.kind))
                        Text(line.text.isEmpty ? " " : line.text)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(line.kind).opacity(line.kind == .same ? 0 : 0.15))
                }
            }
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
        .frame(minHeight: 60, maxHeight: 420)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .same: .primary
        }
    }
}

// MARK: - MQTT 5 properties

struct PropertiesView: View {
    let properties: PublishProperties

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MQTT 5 Properties").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LabeledGrid(items: items)
        }
    }

    private var items: [(String, String)] {
        var out: [(String, String)] = []
        if let v = properties.contentType { out.append(("Content type", v)) }
        if let v = properties.payloadFormatIndicator { out.append(("Payload format", v == 1 ? "UTF-8" : "Bytes")) }
        if let v = properties.responseTopic { out.append(("Response topic", v)) }
        if let v = properties.correlationData {
            out.append(("Correlation data", String(data: v, encoding: .utf8) ?? v.map { String(format: "%02x", $0) }.joined()))
        }
        if let v = properties.messageExpiryInterval { out.append(("Message expiry", "\(v) s")) }
        if !properties.subscriptionIdentifiers.isEmpty {
            out.append(("Subscription IDs", properties.subscriptionIdentifiers.map(String.init).joined(separator: ", ")))
        }
        for up in properties.userProperties { out.append((up.key, up.value)) }
        return out
    }
}

// MARK: - History

struct HistoryPanel: View {
    @Bindable var session: MQTTSession
    let node: TopicNode

    var body: some View {
        let history = Array(node.history.reversed())
        let numeric = history.compactMap { m in session.numericValue(of: m, path: []).map { ChartPoint(date: m.received, value: $0) } }
        VStack(alignment: .leading, spacing: 8) {
            if numeric.count >= 2 && numeric.count == history.count {
                Chart(numeric) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Value", p.value))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Time", p.date), y: .value("Value", p.value))
                        .symbolSize(12)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 110)
                .overlay(alignment: .topTrailing) {
                    Button { session.addChart(topic: node.id, path: []) } label: { Image(systemName: "plus.magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Open in chart panel")
                }
            }
            VStack(spacing: 0) {
                ForEach(history.prefix(200)) { m in
                    HistoryRow(message: m, preview: PayloadDecoder.preview(m.payload, topic: m.topic, maxLength: 80),
                               isSelected: session.selectedHistoryID == m.id || (session.selectedHistoryID == nil && m.id == node.message?.id),
                               isCompared: session.compareHistoryID == m.id)
                        .contentShape(Rectangle())
                        .onTapGesture { session.selectedHistoryID = m.id == node.message?.id ? nil : m.id }
                        .contextMenu {
                            Button("Show") { session.selectedHistoryID = m.id }
                            Button("Compare With Shown Value") { session.compareHistoryID = m.id }
                            Button("Copy Value") { Pasteboard.copy(session.decode(m).text) }
                        }
                    Divider()
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let message: MQTTMessage
    let preview: String
    let isSelected: Bool
    let isCompared: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(Formatters.time.string(from: message.received))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if message.retain { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary) }
            Text(preview.isEmpty ? "(empty)" : preview)
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer(minLength: 0)
            if isCompared { Badge(text: "compare", color: .orange) }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
    }
}
