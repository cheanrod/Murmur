import SwiftUI
import UniformTypeIdentifiers
import MurmurKit

/// The connection manager: saved profiles on the left, the selected profile's settings on the right.
struct ConnectionView: View {
    @Binding var session: MQTTSession?
    @State private var profiles = ProfilesModel.shared
    @State private var selection: UUID?
    @State private var confirmDelete = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Connections") {
                    ForEach(profiles.profiles) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name.isEmpty ? "Untitled" : p.name)
                                .fontWeight(.medium)
                            Text(p.urlDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(p.id)
                        .contextMenu {
                            Button("Connect") { connect(p) }
                            Button("Duplicate") { selection = profiles.duplicate(p.id)?.id }
                            Divider()
                            Button("Delete", role: .destructive) { selection = p.id; confirmDelete = true }
                        }
                    }
                    .onMove { from, to in profiles.profiles.move(fromOffsets: from, toOffset: to) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button { selection = profiles.add().id } label: { Image(systemName: "plus") }
                        .help("Add connection")
                    Button { confirmDelete = true } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help("Delete connection")
                    Spacer()
                    if let error = profiles.lastError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let id = selection, let binding = profiles.binding(for: id) {
                ProfileEditor(profile: binding, session: session, onConnect: { connect(binding.wrappedValue) },
                              onCancel: cancel)
                    .id(id)
            } else {
                ContentUnavailableView("No Connection Selected", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Choose a connection or create a new one with +."))
            }
        }
        .onAppear {
            if let id = session?.profile.id, profiles.profiles.contains(where: { $0.id == id }) {
                selection = id
            } else if selection == nil {
                selection = profiles.profiles.first?.id
            }
        }
        .onChange(of: session?.profile.id) { _, id in
            if let id, profiles.profiles.contains(where: { $0.id == id }) { selection = id }
        }
        .confirmationDialog("Delete this connection?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = selection {
                    profiles.delete(id)
                    selection = profiles.profiles.first?.id
                }
            }
        }
    }

    private func connect(_ profile: ConnectionProfile) {
        session?.cancel()
        profiles.saveNow()
        let s = MQTTSession(profile: profile)
        session = s
        s.connect()
    }

    private func cancel() {
        session?.cancel()
        session = nil
    }
}

private struct ProfileEditor: View {
    @Binding var profile: ConnectionProfile
    let session: MQTTSession?
    let onConnect: () -> Void
    let onCancel: () -> Void

    @State private var showAdvanced = false
    @State private var importing: ImportTarget?
    @State private var importError: String?

    enum ImportTarget: Identifiable {
        case ca, client
        var id: Self { self }
    }

    private var isConnecting: Bool {
        guard let session, session.profile.id == profile.id else { return false }
        switch session.status {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    private var connectError: String? {
        guard let session, session.profile.id == profile.id, case .failed(let e) = session.status else { return nil }
        return e
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $profile.name)
                Picker("Protocol", selection: $profile.transport) {
                    ForEach(TransportProtocol.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: profile.transport) { _, new in adjustDefaultPort(transport: new, tls: profile.useTLS) }
                TextField("Host", text: $profile.host, prompt: Text("broker.example.com"))
                    .textContentType(.URL)
                TextField("Port", value: $profile.port, format: .number.grouping(.never))
                if profile.transport == .websocket {
                    TextField("Base path", text: $profile.basePath, prompt: Text("/mqtt"))
                }
                Toggle("Encryption (TLS)", isOn: $profile.useTLS)
                    .onChange(of: profile.useTLS) { _, new in adjustDefaultPort(transport: profile.transport, tls: new) }
                if profile.useTLS {
                    Toggle("Validate certificate", isOn: $profile.validateCertificate)
                }
            }

            Section {
                TextField("Username", text: $profile.username)
                SecureField("Password", text: $profile.password)
            } header: {
                Text("Authentication")
            } footer: {
                Text("Passwords are stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    advanced
                }
            }

            if let error = connectError ?? importError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            let problems = profile.validationErrors
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(profile.urlDescription)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if isConnecting {
                    ProgressView().controlSize(.small)
                    Text(session?.status.label ?? "").foregroundStyle(.secondary)
                    Button("Cancel", action: onCancel)
                }
                Button("Connect", action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!profile.validationErrors.isEmpty || isConnecting)
            }
            .padding()
            .background(.bar)
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .client ? [.pkcs12, .data] : [.x509Certificate, .data, .text]) { result in
            handleImport(result)
        }
    }

    @ViewBuilder
    private var advanced: some View {
        Picker("MQTT version", selection: $profile.mqttVersion) {
            ForEach(MQTTVersion.allCases) { Text($0.rawValue).tag($0) }
        }
        HStack {
            TextField("Client ID", text: $profile.clientID,
                      prompt: Text(profile.mqttVersion == .v5 ? "Assigned by broker" : "Random"))
            Button { profile.clientID = ConnectionProfile.randomClientID() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Generate a new random client ID")
        }
        Toggle(profile.mqttVersion == .v5 ? "Clean start" : "Clean session", isOn: $profile.cleanSession)
        TextField("Keep alive (seconds)", value: $profile.keepAlive, format: .number.grouping(.never))
        if profile.mqttVersion == .v5 {
            TextField("Session expiry (seconds)", value: $profile.sessionExpiry, format: .number.grouping(.never))
        }
        Toggle("Reconnect automatically", isOn: $profile.autoReconnect)

        LabeledContent("Subscriptions") {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach($profile.subscriptions) { $sub in
                    HStack {
                        TextField("Topic filter", text: $sub.topic)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        Picker("", selection: $sub.qos) {
                            ForEach(QoS.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Button {
                            profile.subscriptions.removeAll { $0.id == sub.id }
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Reset to defaults") { profile.subscriptions = ConnectionProfile.defaultSubscriptions }
                    Button("Add Subscription") { profile.subscriptions.append(SubscriptionConfig(topic: "")) }
                }
                .controlSize(.small)
            }
        }

        LabeledContent("Server CA certificate") {
            certificateRow(file: profile.caCertificate, import: { importing = .ca }, remove: { profile.caCertificate = nil })
        }
        LabeledContent("Client certificate (.p12)") {
            certificateRow(file: profile.clientCertificate, import: { importing = .client },
                           remove: { profile.clientCertificate = nil })
        }
        if profile.clientCertificate != nil {
            SecureField("Client certificate password", text: $profile.clientCertificatePassword)
        }
        if profile.useTLS {
            TextField("ALPN protocols", text: $profile.alpn, prompt: Text("comma separated, e.g. x-amzn-mqtt-ca"))
        }

        Toggle("Last will", isOn: $profile.lastWillEnabled)
        if profile.lastWillEnabled {
            TextField("Will topic", text: $profile.lastWill.topic)
            TextField("Will payload", text: $profile.lastWill.payload, axis: .vertical)
                .lineLimit(1...4)
            Picker("Will QoS", selection: $profile.lastWill.qos) {
                ForEach(QoS.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Retain will", isOn: $profile.lastWill.retain)
        }
    }

    private func certificateRow(file: EmbeddedFile?, import doImport: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack {
            if let file {
                Label(file.name, systemImage: "checkmark.seal")
                    .lineLimit(1)
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            } else {
                Text("None").foregroundStyle(.secondary)
            }
            Button("Choose…", action: doImport)
        }
    }

    private func adjustDefaultPort(transport: TransportProtocol, tls: Bool) {
        let defaults: Set<UInt16> = [1883, 8883, 80, 443, 8080, 8081, 9001]
        guard defaults.contains(profile.port) else { return }
        switch (transport, tls) {
        case (.mqtt, false): profile.port = 1883
        case (.mqtt, true): profile.port = 8883
        case (.websocket, false): profile.port = profile.port == 9001 || profile.port == 8080 ? profile.port : 8080
        case (.websocket, true): profile.port = 8081
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        let target = importing
        importing = nil
        importError = nil
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let file = EmbeddedFile(name: url.lastPathComponent, data: data)
                if target == .ca {
                    let certs = try CertificateLoader.certificates(from: data)
                    guard !certs.isEmpty else { throw DraftError("No certificate found in file") }
                    profile.caCertificate = file
                } else {
                    profile.clientCertificate = file
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
