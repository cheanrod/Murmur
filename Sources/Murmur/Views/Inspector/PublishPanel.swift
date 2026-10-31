import SwiftUI
import UniformTypeIdentifiers
import MurmurKit

struct PublishPanel: View {
    @Bindable var session: MQTTSession
    @State private var showProperties = false
    @State private var importing = false
    @State private var flash = false

    private var isV5: Bool { session.profile.mqttVersion == .v5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Topic", text: $session.publishDraft.topic, prompt: Text("topic/to/publish"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                if let selected = session.selectedTopic, selected != session.publishDraft.topic {
                    Button { session.publishDraft.topic = selected } label: { Image(systemName: "arrow.uturn.left") }
                        .buttonStyle(.borderless)
                        .help("Use selected topic")
                }
            }

            HStack {
                Picker("Format", selection: $session.publishDraft.format) {
                    ForEach(PublishFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer(minLength: 4)
                if session.publishDraft.format == .json || session.publishDraft.format == .xml {
                    Button("Format", action: formatPayload)
                        .controlSize(.small)
                        .help("Pretty-print the payload")
                }
                Button { importing = true } label: { Image(systemName: "doc.badge.arrow.up") }
                    .buttonStyle(.borderless)
                    .help("Load payload from a file")
            }

            TextEditor(text: $session.publishDraft.payload)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 90, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(validation == nil ? Color.secondary.opacity(0.3) : .orange))

            if let validation {
                Label(validation, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Picker("QoS", selection: $session.publishDraft.qos) {
                    ForEach(QoS.allCases) { Text("\($0.rawValue)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Retain", isOn: $session.publishDraft.retain)
                    .fixedSize()
                Spacer()
            }
            HStack {
                historyMenu
                Spacer()
                Button {
                    session.publish(session.publishDraft)
                    flash.toggle()
                } label: {
                    Label("Publish", systemImage: "paperplane.fill")
                        .symbolEffect(.bounce, value: flash)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.status != .connected || session.publishDraft.topic.isEmpty)
                .help("Publish (⌘↩)")
            }

            if isV5 {
                DisclosureGroup("MQTT 5 properties", isExpanded: $showProperties) {
                    propertiesEditor.padding(.top, 4)
                }
                .font(.callout)
            }

            if let error = session.lastPublishError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text, .json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            if let text = String(data: data, encoding: .utf8) {
                session.publishDraft.payload = text
                session.publishDraft.format = JSONValue.parse(data) != nil ? .json : .text
            } else {
                session.publishDraft.payload = data.base64EncodedString()
                session.publishDraft.format = .base64
            }
        }
    }

    private var validation: String? {
        let d = session.publishDraft
        if !d.topic.isEmpty, let e = TopicValidation.validatePublishTopic(d.topic) { return e }
        guard !d.payload.isEmpty else { return nil }
        switch d.format {
        case .json: return JSONValue.validationError(d.payload).map { "Invalid JSON: \($0)" }
        case .xml:
            let parser = XMLParser(data: Data(d.payload.utf8))
            return parser.parse() ? nil : "Invalid XML: \(parser.parserError?.localizedDescription ?? "parse error")"
        case .hex: return PayloadDecoder.data(fromHex: d.payload) == nil ? "Invalid hex" : nil
        case .base64:
            return Data(base64Encoded: d.payload.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ? "Invalid Base64" : nil
        case .text: return nil
        }
    }

    private func formatPayload() {
        let d = session.publishDraft
        switch d.format {
        case .json:
            if let json = JSONValue.parse(d.payload) { session.publishDraft.payload = json.serialized() }
        case .xml:
            if let doc = try? XMLDocument(xmlString: d.payload, options: [.nodePreserveAll]) {
                session.publishDraft.payload = doc.xmlString(options: [.nodePrettyPrint])
            }
        default:
            break
        }
    }

    private var historyMenu: some View {
        Menu {
            if session.publishHistory.isEmpty {
                Text("No recent messages")
            } else {
                ForEach(session.publishHistory) { entry in
                    Button {
                        var restored = entry
                        restored.id = UUID()
                        session.publishDraft = restored
                    } label: {
                        Text("\(entry.topic) — \(String(entry.payload.prefix(40)).replacingOccurrences(of: "\n", with: " "))")
                    }
                }
                Divider()
                Button("Clear History", role: .destructive) { session.clearPublishHistory() }
            }
        } label: {
            Label("Recent", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Recently published messages")
    }

    @ViewBuilder
    private var propertiesEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Content type").foregroundStyle(.secondary)
                TextField("", text: $session.publishDraft.contentType,
                          prompt: Text(session.publishDraft.format == .json ? "application/json" : "text/plain"))
            }
            GridRow {
                Text("Response topic").foregroundStyle(.secondary)
                TextField("", text: $session.publishDraft.responseTopic)
            }
            GridRow {
                Text("Correlation data").foregroundStyle(.secondary)
                TextField("", text: $session.publishDraft.correlationData)
            }
            GridRow {
                Text("Expiry (s)").foregroundStyle(.secondary)
                TextField("", text: $session.publishDraft.messageExpiry, prompt: Text("none"))
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("User properties").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    session.publishDraft.userProperties.append(UserProperty(key: "", value: ""))
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
            ForEach($session.publishDraft.userProperties) { $prop in
                HStack {
                    TextField("Key", text: $prop.key)
                    TextField("Value", text: $prop.value)
                    Button {
                        session.publishDraft.userProperties.removeAll { $0.id == prop.id }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}
