import SwiftUI
import MurmurKit

@main
struct MurmurApp: App {
    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .system

    init() {
        // Lets `swift run` show a regular app with a Dock icon even without an .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        #if DEBUG
        DispatchQueue.main.async { DebugSnapshot.startIfRequested() }
        #endif
    }

    var body: some Scene {
        WindowGroup("Murmur", id: "main") {
            ContentView()
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Murmur") { showAboutPanel() }
            }
            SessionCommands()
        }

        Settings {
            SettingsView()
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// Standard About window, with the full git-derived version and the name's origin as credits.
@MainActor
private func showAboutPanel() {
    let credits = NSAttributedString(
        string: "Murmur: from murmuration, a flock of starlings moving as one.\n\n\(AppVersion.full)",
        attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    )
    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationVersion: AppVersion.version,
        .version: AppVersion.build,
        .credits: credits,
    ])
    NSApp.activate()
}

// MARK: - Focused session for menu commands

struct FocusedSessionKey: FocusedValueKey {
    typealias Value = MQTTSession
}

extension FocusedValues {
    var session: MQTTSession? {
        get { self[FocusedSessionKey.self] }
        set { self[FocusedSessionKey.self] = newValue }
    }
}

struct SessionCommands: Commands {
    @FocusedValue(\.session) private var session

    var body: some Commands {
        CommandMenu("Connection") {
            Button(session?.isPaused == true ? "Resume Updates" : "Pause Updates") { session?.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Clear Topic Tree") { session?.clearTree() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(session == nil)
            Divider()
            Button("Expand All") { session?.expandAll() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Collapse All") { session?.collapseAll() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(session == nil)
            Divider()
            Button(session?.showCharts == true ? "Hide Charts" : "Show Charts") { session?.showCharts.toggle() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(session == nil)
            Divider()
            Button("Copy Selected Topic") {
                if let t = session?.selectedTopic { Pasteboard.copy(t) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(session?.selectedTopic == nil)
            Divider()
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session == nil)
        }
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
