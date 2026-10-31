import SwiftUI
import MurmurKit

struct TopicTreeView: View {
    @Bindable var session: MQTTSession
    @AppStorage(SettingsKey.highlightUpdates) private var highlightUpdates = true
    @AppStorage(SettingsKey.showValuePreview) private var showValuePreview = true
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        Group {
            if session.rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List(selection: $session.selectedTopic) {
                        ForEach(session.rows) { row in
                            TopicRowView(
                                row: row,
                                highlight: highlightUpdates,
                                showPreview: showValuePreview,
                                toggle: { session.toggleExpanded(row.id) }
                            )
                            .tag(row.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                            .contextMenu { contextMenu(for: row) }
                        }
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds(.enabled)
                    .environment(\.defaultMinListRowHeight, 22)
                    .onKeyPress(.rightArrow) { session.expandOrSelectChild(); return .handled }
                    .onKeyPress(.leftArrow) { session.collapseOrSelectParent(); return .handled }
                    .onKeyPress(.space) {
                        if let t = session.selectedTopic { session.toggleExpanded(t) }
                        return .handled
                    }
                    .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                        if let t = session.selectedTopic { pendingDelete = DeleteRequest(path: t, recursive: false) }
                        return .handled
                    }
                    .onChange(of: session.selectedTopic) { _, t in
                        if let t { withAnimation { proxy.scrollTo(t) } }
                    }
                }
            }
        }
        .deleteConfirmation(session: session, request: $pendingDelete)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !session.searchText.isEmpty {
            ContentUnavailableView.search(text: session.searchText)
        } else if session.isPaused {
            ContentUnavailableView("Paused", systemImage: "pause.circle",
                                   description: Text("\(session.pausedCount) messages buffered"))
        } else {
            ContentUnavailableView {
                Label("Waiting for messages", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Subscribed to " + session.profile.subscriptions.map(\.topic).joined(separator: ", "))
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for row: TopicRow) -> some View {
        Button("Copy Topic") { Pasteboard.copy(row.id) }
        if let m = session.tree.node(for: row.id)?.message {
            Button("Copy Value") { Pasteboard.copy(session.decode(m).text) }
        }
        Divider()
        if row.hasChildren {
            Button(row.isExpanded ? "Collapse" : "Expand") { session.toggleExpanded(row.id) }
            Button("Expand All Below") { session.expandAll(under: row.id) }
        }
        Button("Publish to This Topic") {
            session.selectedTopic = row.id
            session.publishDraft.topic = row.id
        }
        Button("Search This Branch") { session.searchText = row.id }
        Divider()
        if row.hasValue {
            Button("Delete Retained Message", role: .destructive) {
                pendingDelete = DeleteRequest(path: row.id, recursive: false)
            }
        }
        if row.hasChildren {
            Button("Delete Topic and Subtopics…", role: .destructive) {
                pendingDelete = DeleteRequest(path: row.id, recursive: true)
            }
        }
    }
}

struct TopicRowView: View {
    let row: TopicRow
    let highlight: Bool
    let showPreview: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(row.hasChildren ? 1 : 0)
            .disabled(!row.hasChildren)

            Text(row.name.isEmpty ? "∅" : row.name)
                .fontWeight(row.hasValue ? .semibold : .regular)
                .foregroundStyle(row.name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)

            if row.hasValue && showPreview {
                Text("= " + row.preview)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if row.isRetained {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("Retained")
            }

            if row.hasChildren {
                Text("(\(row.topicCount) \(row.topicCount == 1 ? "topic" : "topics"), \(row.messageCount) \(row.messageCount == 1 ? "message" : "messages"))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background {
            if highlight {
                FlashBackground(trigger: row.flashToken)
            }
        }
    }
}

/// Briefly tints the row when `trigger` changes.
private struct FlashBackground: View {
    let trigger: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                LinearKeyframe(0.28, duration: 0.05)
                LinearKeyframe(0.0, duration: 0.8)
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Deleting

struct DeleteRequest: Identifiable {
    var id: String { path + (recursive ? "/#" : "") }
    let path: String
    let recursive: Bool
}

private struct DeleteConfirmation: ViewModifier {
    let session: MQTTSession
    @Binding var request: DeleteRequest?
    @AppStorage(SettingsKey.confirmDeletes) private var confirmDeletes = true

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, _ in
                if let r = request, !confirmDeletes {
                    perform(r)
                    request = nil
                }
            }
            .confirmationDialog(
                title,
                isPresented: Binding(get: { request != nil && confirmDeletes }, set: { if !$0 { request = nil } }),
                titleVisibility: .visible,
                presenting: request
            ) { r in
                Button(r.recursive ? "Delete \(count(r)) Topics" : "Delete", role: .destructive) { perform(r) }
            } message: { r in
                Text(r.recursive
                     ? "Publishes an empty retained message to \(r.path) and every subtopic that has a value. This clears retained messages on the broker."
                     : "Publishes an empty retained message to \(r.path), which clears its retained message on the broker.")
            }
    }

    private var title: String {
        guard let r = request else { return "" }
        return r.recursive ? "Delete “\(r.path)” and all subtopics?" : "Delete retained message of “\(r.path)”?"
    }

    private func count(_ r: DeleteRequest) -> Int {
        guard let node = session.tree.node(for: r.path) else { return 0 }
        return session.tree.valueNodes(under: node).count
    }

    private func perform(_ r: DeleteRequest) {
        if r.recursive {
            _ = session.deleteRecursively(r.path)
        } else {
            session.deleteRetained(topic: r.path)
        }
    }
}

extension View {
    func deleteConfirmation(session: MQTTSession, request: Binding<DeleteRequest?>) -> some View {
        modifier(DeleteConfirmation(session: session, request: request))
    }
}
