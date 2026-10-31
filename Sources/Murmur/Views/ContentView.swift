import SwiftUI
import MurmurKit

/// Root of each window: the connection screen until a session is established, then the explorer.
struct ContentView: View {
    @State private var session: MQTTSession?

    var body: some View {
        Group {
            if let session, session.hasConnectedOnce, session.status != .disconnected {
                ExplorerView(session: session)
                    .focusedSceneValue(\.session, session)
                    .navigationTitle(session.profile.name)
                    .navigationSubtitle(session.profile.urlDescription)
            } else {
                ConnectionView(session: $session)
                    .navigationTitle("Murmur")
            }
        }
        .onAppear(perform: autoConnectFromLaunchArguments)
        .onChange(of: session?.status) { _, newStatus in
            // A user initiated disconnect returns to the connection screen.
            if newStatus == .disconnected, session?.hasConnectedOnce == true {
                session?.cancel()
                session = nil
            }
        }
    }

    /// `Murmur --connect mqtt://host:port` connects the first window immediately (handy for scripting and development).
    private func autoConnectFromLaunchArguments() {
        guard !Self.didAutoConnect else { return }
        Self.didAutoConnect = true
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--connect"), i + 1 < args.count,
              let url = URLComponents(string: args[i + 1]), let host = url.host else { return }
        let tls = url.scheme == "mqtts" || url.scheme == "wss"
        let ws = url.scheme == "ws" || url.scheme == "wss"
        var profile = ProfilesModel.shared.profiles.first { $0.host == host && Int($0.port) == (url.port ?? 1883) }
            ?? ConnectionProfile(name: host, host: host)
        profile.port = UInt16(url.port ?? (tls ? (ws ? 8081 : 8883) : (ws ? 8080 : 1883)))
        profile.useTLS = tls
        profile.transport = ws ? .websocket : .mqtt
        if ws, !url.path.isEmpty { profile.basePath = url.path }
        let s = MQTTSession(profile: profile)
        session = s
        s.connect()
        #if DEBUG
        if let topic = ProcessInfo.processInfo.environment["MURMUR_DEBUG_SELECT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                s.reveal(topic)
                if let path = ProcessInfo.processInfo.environment["MURMUR_DEBUG_CHART"] {
                    s.addChart(topic: topic, path: path.isEmpty ? [] : path.components(separatedBy: "."))
                }
            }
        }
        #endif
    }

    @MainActor private static var didAutoConnect = false
}
