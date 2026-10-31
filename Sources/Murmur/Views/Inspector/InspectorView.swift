import SwiftUI
import MurmurKit

/// Right-hand sidebar: topic, value, history, publish and statistics panels.
struct InspectorView: View {
    @Bindable var session: MQTTSession

    @AppStorage("inspector.topic") private var topicOpen = true
    @AppStorage("inspector.value") private var valueOpen = true
    @AppStorage("inspector.history") private var historyOpen = true
    @AppStorage("inspector.publish") private var publishOpen = true
    @AppStorage("inspector.stats") private var statsOpen = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                InspectorSection("Topic", systemImage: "number", isExpanded: $topicOpen) {
                    TopicPanel(session: session)
                }
                InspectorSection("Value", systemImage: "doc.text", isExpanded: $valueOpen) {
                    ValuePanel(session: session)
                }
                if let node = session.selectedNode, node.history.count > 0 {
                    InspectorSection("History (\(node.history.count))", systemImage: "clock.arrow.circlepath",
                                     isExpanded: $historyOpen) {
                        HistoryPanel(session: session, node: node)
                    }
                }
                InspectorSection("Publish", systemImage: "paperplane", isExpanded: $publishOpen) {
                    PublishPanel(session: session)
                }
                InspectorSection("Stats", systemImage: "chart.bar", isExpanded: $statsOpen) {
                    StatsPanel(session: session)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                content
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

// MARK: - Topic

struct TopicPanel: View {
    @Bindable var session: MQTTSession
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        if let node = session.selectedNode {
            VStack(alignment: .leading, spacing: 8) {
                Breadcrumb(nodes: node.pathNodes) { session.reveal($0) }
                HStack(spacing: 8) {
                    Button { Pasteboard.copy(node.id) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .help("Copy topic")
                    if node.hasValue {
                        Button(role: .destructive) {
                            pendingDelete = DeleteRequest(path: node.id, recursive: false)
                        } label: { Label("Delete", systemImage: "trash") }
                            .help("Clear the retained message of this topic")
                    }
                    let subCount = node.subtreeTopicCount
                    if subCount > 0 {
                        Button(role: .destructive) {
                            pendingDelete = DeleteRequest(path: node.id, recursive: true)
                        } label: { Label("Delete \(subCount + (node.hasValue ? 1 : 0)) topics", systemImage: "trash.fill") }
                            .help("Clear this topic and all subtopics")
                    }
                }
                .controlSize(.small)
                LabeledGrid(items: [
                    ("Messages", Formatters.number(node.ownMessageCount)),
                    ("Subtopics", Formatters.number(node.subtreeTopicCount)),
                    ("Messages in branch", Formatters.number(node.subtreeMessageCount)),
                ])
            }
            .deleteConfirmation(session: session, request: $pendingDelete)
        } else {
            Text("Select a topic in the tree.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct Breadcrumb: View {
    let nodes: [TopicNode]
    let select: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) { content }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 2) { content } }
        }
        .font(.body.monospaced())
    }

    @ViewBuilder private var content: some View {
        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
            if index > 0 { Text("/").foregroundStyle(.tertiary) }
            Button(node.name.isEmpty ? "∅" : node.name) { select(node.id) }
                .buttonStyle(.plain)
                .foregroundStyle(index == nodes.count - 1 ? Color.primary : Color.accentColor)
                .fontWeight(index == nodes.count - 1 ? .semibold : .regular)
        }
    }
}

struct LabeledGrid: View {
    let items: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.0).foregroundStyle(.secondary)
                    Text(item.1).textSelection(.enabled).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}
