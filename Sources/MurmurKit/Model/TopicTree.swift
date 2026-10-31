import Foundation

/// A node in the topic hierarchy. Reference type so the tree can be mutated cheaply at high message rates.
public final class TopicNode: Identifiable {
    /// The full topic path (also used as identity). The root node has an empty path.
    public let id: String
    /// The last path segment.
    public let name: String
    public private(set) weak var parent: TopicNode?
    public private(set) var children: [String: TopicNode] = [:]
    /// Children in order of first appearance.
    public private(set) var orderedChildren: [TopicNode] = []
    public private(set) var message: MQTTMessage?
    /// Most recent messages (oldest first), bounded by the tree's history limit.
    public private(set) var history: [MQTTMessage] = []
    public private(set) var preview: String = ""
    public private(set) var ownMessageCount = 0
    public private(set) var subtreeMessageCount = 0
    /// Number of descendants (excluding self) that currently hold a value.
    public private(set) var subtreeTopicCount = 0
    public private(set) var lastUpdate: Date?
    /// Increments whenever this node receives a message.
    public private(set) var updateSequence = 0
    /// Increments whenever this node or any descendant receives a message.
    public private(set) var subtreeUpdateSequence = 0
    public let depth: Int

    init(path: String, name: String, parent: TopicNode?) {
        self.id = path
        self.name = name
        self.parent = parent
        self.depth = (parent?.depth ?? -1) + 1
    }

    public var isRoot: Bool { parent == nil }
    public var hasValue: Bool { message != nil }
    public var path: String { id }

    /// Ancestors from the top-level node down to (and including) self. Excludes the root.
    public var pathNodes: [TopicNode] {
        var nodes: [TopicNode] = []
        var current: TopicNode? = self
        while let n = current, !n.isRoot {
            nodes.append(n)
            current = n.parent
        }
        return nodes.reversed()
    }

    /// All descendants, depth first (excluding self).
    public var descendants: [TopicNode] {
        var out: [TopicNode] = []
        var stack = orderedChildren.reversed() as [TopicNode]
        while let n = stack.popLast() {
            out.append(n)
            stack.append(contentsOf: n.orderedChildren.reversed())
        }
        return out
    }

    fileprivate func child(named name: String) -> TopicNode {
        if let c = children[name] { return c }
        let path = isRoot ? name : id + "/" + name
        let c = TopicNode(path: path, name: name, parent: self)
        children[name] = c
        orderedChildren.append(c)
        return c
    }

    fileprivate func removeChild(_ node: TopicNode) {
        children.removeValue(forKey: node.name)
        orderedChildren.removeAll { $0 === node }
    }

    fileprivate func record(_ m: MQTTMessage, historyLimit: Int) {
        message = m
        preview = PayloadDecoder.preview(m.payload, topic: m.topic)
        ownMessageCount += 1
        lastUpdate = m.received
        updateSequence += 1
        history.append(m)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    fileprivate func clearValue() {
        message = nil
        preview = ""
        lastUpdate = Date()
        updateSequence += 1
    }

    fileprivate func trimHistory(to limit: Int) {
        if history.count > limit { history.removeFirst(history.count - limit) }
        for c in orderedChildren { c.trimHistory(to: limit) }
    }

    fileprivate func adjustAncestors(messages: Int, topics: Int) {
        var current: TopicNode? = self
        while let n = current {
            n.subtreeMessageCount += messages
            n.subtreeUpdateSequence += 1
            current = n.parent
        }
        guard topics != 0 else { return }
        current = parent
        while let n = current {
            n.subtreeTopicCount += topics
            current = n.parent
        }
    }
}

public enum TopicOrder: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, alphabetical, messages, topics
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "Arrival"
        case .alphabetical: "Name (A–Z)"
        case .messages: "Most messages"
        case .topics: "Most subtopics"
        }
    }
}

public enum AutoExpand: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, few, some, most, all
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: "Off"
        case .few: "Few"
        case .some: "Some"
        case .most: "Most"
        case .all: "All"
        }
    }
    /// Nodes with at most this many sub-topics are expanded automatically.
    public var threshold: Int {
        switch self {
        case .off: -1
        case .few: 3
        case .some: 10
        case .most: 50
        case .all: .max
        }
    }
}

/// A flattened, display-ready row of the visible tree.
public struct TopicRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let hasValue: Bool
    public let preview: String
    public let isRetained: Bool
    public let topicCount: Int
    public let messageCount: Int
    /// Changes whenever the row should flash.
    public let flashToken: Int
}

public final class TopicTree {
    public let root = TopicNode(path: "", name: "", parent: nil)
    public private(set) var nodesByPath: [String: TopicNode] = [:]
    public private(set) var totalMessages = 0
    public private(set) var totalBytes = 0
    public var historyLimit: Int {
        didSet { if historyLimit < oldValue { root.trimHistory(to: historyLimit) } }
    }

    public init(historyLimit: Int = 100) {
        self.historyLimit = max(1, historyLimit)
    }

    public var topicCount: Int { root.subtreeTopicCount }

    public func node(for path: String) -> TopicNode? { nodesByPath[path] }

    /// Applies a received message. Empty payloads remove the topic's value (MQTT's way of deleting retained messages).
    @discardableResult
    public func apply(_ m: MQTTMessage) -> TopicNode? {
        totalMessages += 1
        totalBytes += m.payload.count

        if m.payload.isEmpty {
            guard let node = nodesByPath[m.topic] else { return nil }
            removeValue(of: node, countMessage: true)
            return node
        }

        var node = root
        for segment in m.topic.split(separator: "/", omittingEmptySubsequences: false) {
            let isNew = node.children[String(segment)] == nil
            node = node.child(named: String(segment))
            if isNew { nodesByPath[node.id] = node }
        }
        let wasEmpty = !node.hasValue
        node.record(m, historyLimit: historyLimit)
        node.adjustAncestors(messages: 1, topics: wasEmpty ? 1 : 0)
        return node
    }

    private func removeValue(of node: TopicNode, countMessage: Bool) {
        let hadValue = node.hasValue
        node.clearValue()
        node.adjustAncestors(messages: countMessage ? 1 : 0, topics: hadValue ? -1 : 0)
        prune(node)
    }

    /// Removes nodes that have neither a value nor children, walking up.
    private func prune(_ node: TopicNode) {
        var current: TopicNode? = node
        while let n = current, !n.isRoot, !n.hasValue, n.orderedChildren.isEmpty, let parent = n.parent {
            // Subtract this node's own messages from ancestor counters, it is going away.
            if n.ownMessageCount > 0 { parent.subtractMessages(n.ownMessageCount) }
            parent.removeChild(n)
            nodesByPath.removeValue(forKey: n.id)
            current = parent
        }
    }

    public func clear() {
        for c in root.orderedChildren { root.removeChild(c) }
        nodesByPath.removeAll()
        totalMessages = 0
        totalBytes = 0
        root.resetCounters()
    }

    /// Nodes in the subtree (including `node`) that hold a retained value.
    public func retainedNodes(under node: TopicNode) -> [TopicNode] {
        ([node] + node.descendants).filter { $0.message?.retain == true }
    }

    /// Nodes in the subtree (including `node`) that hold any value.
    public func valueNodes(under node: TopicNode) -> [TopicNode] {
        ([node] + node.descendants).filter(\.hasValue)
    }

    // MARK: - Flattening

    public struct ViewOptions: Sendable {
        public var expanded: Set<String> = []
        public var collapsed: Set<String> = []
        public var order: TopicOrder = .none
        public var autoExpand: AutoExpand = .off
        public var filter: String = ""
        public init() {}
    }

    public func isExpanded(_ node: TopicNode, options: ViewOptions) -> Bool {
        if options.expanded.contains(node.id) { return true }
        if options.collapsed.contains(node.id) { return false }
        return node.subtreeTopicCount <= options.autoExpand.threshold
    }

    public func sortedChildren(of node: TopicNode, order: TopicOrder) -> [TopicNode] {
        switch order {
        case .none:
            return node.orderedChildren
        case .alphabetical:
            return node.orderedChildren.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .messages:
            return node.orderedChildren.sorted { $0.subtreeMessageCount > $1.subtreeMessageCount }
        case .topics:
            return node.orderedChildren.sorted {
                $0.subtreeTopicCount != $1.subtreeTopicCount
                    ? $0.subtreeTopicCount > $1.subtreeTopicCount
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Produces the list of visible rows given expansion state, ordering and an optional search filter.
    public func visibleRows(options: ViewOptions) -> [TopicRow] {
        var rows: [TopicRow] = []
        rows.reserveCapacity(256)
        let needle = options.filter.trimmingCharacters(in: .whitespaces).lowercased()

        if needle.isEmpty {
            for child in sortedChildren(of: root, order: options.order) {
                appendRows(child, options: options, into: &rows)
            }
            return rows
        }

        // With a filter: precompute which nodes are on a path to a match.
        var relevant: Set<ObjectIdentifier> = []
        var selfMatch: Set<ObjectIdentifier> = []
        func mark(_ node: TopicNode) -> Bool {
            var any = false
            for c in node.orderedChildren where mark(c) { any = true }
            let matches = !node.isRoot && (node.id.lowercased().contains(needle) || node.preview.lowercased().contains(needle))
            if matches { selfMatch.insert(ObjectIdentifier(node)) }
            if matches || any { relevant.insert(ObjectIdentifier(node)) }
            return matches || any
        }
        _ = mark(root)

        func appendFiltered(_ node: TopicNode) {
            let oid = ObjectIdentifier(node)
            if selfMatch.contains(oid) && !node.orderedChildren.contains(where: { relevant.contains(ObjectIdentifier($0)) }) {
                // A matching leaf of the search: show it, honoring normal expansion below it.
                appendRows(node, options: options, into: &rows)
                return
            }
            let expanded = !options.collapsed.contains(node.id)
            rows.append(row(for: node, expanded: expanded))
            guard expanded else { return }
            for c in sortedChildren(of: node, order: options.order) where relevant.contains(ObjectIdentifier(c)) {
                appendFiltered(c)
            }
        }
        for c in sortedChildren(of: root, order: options.order) where relevant.contains(ObjectIdentifier(c)) {
            appendFiltered(c)
        }
        return rows
    }

    private func appendRows(_ node: TopicNode, options: ViewOptions, into rows: inout [TopicRow]) {
        let expanded = !node.orderedChildren.isEmpty && isExpanded(node, options: options)
        rows.append(row(for: node, expanded: expanded))
        guard expanded else { return }
        for c in sortedChildren(of: node, order: options.order) {
            appendRows(c, options: options, into: &rows)
        }
    }

    private func row(for node: TopicNode, expanded: Bool) -> TopicRow {
        TopicRow(
            id: node.id,
            name: node.name,
            depth: node.depth - 1,
            hasChildren: !node.orderedChildren.isEmpty,
            isExpanded: expanded,
            hasValue: node.hasValue,
            preview: node.preview,
            isRetained: node.message?.retain ?? false,
            topicCount: node.subtreeTopicCount,
            messageCount: node.subtreeMessageCount,
            flashToken: expanded ? node.updateSequence : node.subtreeUpdateSequence
        )
    }
}

extension TopicNode {
    fileprivate func subtractMessages(_ count: Int) {
        var current: TopicNode? = self
        while let n = current { n.subtreeMessageCount -= count; current = n.parent }
    }

    fileprivate func resetCounters() {
        subtreeMessageCount = 0
        subtreeTopicCount = 0
        subtreeUpdateSequence += 1
    }
}
