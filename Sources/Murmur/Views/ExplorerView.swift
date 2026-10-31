import SwiftUI
import MurmurKit

/// Main window while connected: topic tree, inspector sidebar, optional chart panel.
struct ExplorerView: View {
    @Bindable var session: MQTTSession
    @State private var showSettings = false

    @AppStorage(SettingsKey.topicOrder) private var topicOrder: TopicOrder = .none
    @AppStorage(SettingsKey.autoExpand) private var autoExpand: AutoExpand = .off
    @AppStorage(SettingsKey.historyLimit) private var historyLimit = SettingsDefault.historyLimit
    @AppStorage(SettingsKey.maxChartPoints) private var maxChartPoints = SettingsDefault.maxChartPoints

    var body: some View {
        VStack(spacing: 0) {
            if session.status != .connected {
                StatusBanner(status: session.status)
            }
            if session.status == .connected, !session.failedSubscriptions.isEmpty {
                SubscriptionWarning(filters: session.failedSubscriptions)
            }
            VSplitView {
                HSplitView {
                    TopicTreeView(session: session)
                        .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    InspectorView(session: session)
                        .frame(minWidth: 340, idealWidth: 440, maxWidth: 900, maxHeight: .infinity)
                }
                .frame(minHeight: 280)
                if session.showCharts {
                    ChartPanel(session: session)
                        .frame(minHeight: 180, idealHeight: 260)
                }
            }
            Divider()
            StatusBar(session: session)
        }
        .searchable(text: $session.searchText, placement: .toolbar, prompt: "Search topics and values")
        .toolbar { toolbar }
        .onAppear {
            session.setOrder(topicOrder)
            session.setAutoExpand(autoExpand)
        }
        .onChange(of: topicOrder) { _, v in session.setOrder(v) }
        .onChange(of: autoExpand) { _, v in session.setAutoExpand(v) }
        .onChange(of: historyLimit) { _, v in session.setHistoryLimit(v) }
        .onChange(of: maxChartPoints) { _, v in session.setMaxChartPoints(v) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Sort", selection: $topicOrder) {
                ForEach(TopicOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Topic order")

            Button {
                session.togglePause()
            } label: {
                Label(session.isPaused ? "Resume" : "Pause",
                      systemImage: session.isPaused ? "play.fill" : "pause.fill")
            }
            .help(session.isPaused ? "Resume (\(session.pausedCount) buffered messages)" : "Pause tree updates")
            .overlay(alignment: .topTrailing) {
                if session.isPaused && session.pausedCount > 0 {
                    Text(session.pausedCount > 999 ? "999+" : "\(session.pausedCount)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(.orange))
                        .foregroundStyle(.white)
                        .offset(x: 6, y: -4)
                }
            }

            Button { session.clearTree() } label: { Label("Clear", systemImage: "trash.slash") }
                .help("Clear the topic tree (⌘K)")

            Button { session.showCharts.toggle() } label: {
                Label("Charts", systemImage: "chart.xyaxis.line")
            }
            .help("Show or hide the chart panel")

            Button { showSettings.toggle() } label: { Label("Settings", systemImage: "gearshape") }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsView().frame(width: 380)
                }

            Button { session.disconnect() } label: {
                Label("Disconnect", systemImage: "eject.fill")
            }
            .help("Disconnect (⇧⌘D)")
        }
    }
}

private struct StatusBanner: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 8) {
            if case .reconnecting = status { ProgressView().controlSize(.small) }
            Image(systemName: "exclamationmark.triangle.fill")
            Text(status.label).lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(status.color.gradient)
    }
}

private struct StatusBar: View {
    let session: MQTTSession

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(session.status.color).frame(width: 7, height: 7)
                Text(session.status.label).lineLimit(1)
            }
            Divider().frame(height: 12)
            Text("\(Formatters.number(session.tree.topicCount)) topics")
            Text("\(Formatters.number(session.tree.totalMessages)) messages")
            Text("\(Int(session.messageRate)) msg/s")
            Text(Formatters.bytes(session.tree.totalBytes))
            if session.isPaused {
                Label("Paused · \(Formatters.number(session.pausedCount)) buffered", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let t = session.selectedTopic {
                Text(t).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .id(session.revision)
    }
}

private struct SubscriptionWarning: View {
    let filters: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("The broker rejected the subscription to \(filters.map { "“\($0)”" }.joined(separator: ", ")). Many public brokers don't allow “#”; subscribe to a narrower topic such as “home/#” instead.")
                .lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.gradient)
    }
}
