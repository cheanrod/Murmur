import Foundation
import Testing
@testable import MurmurKit

@Suite struct TopicTreeTests {
    func msg(_ topic: String, _ payload: String, retain: Bool = false) -> MQTTMessage {
        MQTTMessage(topic: topic, payload: Data(payload.utf8), retain: retain)
    }

    @Test func countsAndHistory() {
        let tree = TopicTree(historyLimit: 2)
        tree.apply(msg("home/kitchen/temp", "20"))
        tree.apply(msg("home/kitchen/temp", "21"))
        tree.apply(msg("home/kitchen/temp", "22"))
        tree.apply(msg("home/living/temp", "19"))
        tree.apply(msg("home", "root value"))
        #expect(tree.topicCount == 3)
        #expect(tree.totalMessages == 5)
        let home = tree.node(for: "home")!
        #expect(home.subtreeTopicCount == 2)
        #expect(home.subtreeMessageCount == 5)
        let temp = tree.node(for: "home/kitchen/temp")!
        #expect(temp.history.map { String(decoding: $0.payload, as: UTF8.self) } == ["21", "22"])
        #expect(temp.pathNodes.map(\.name) == ["home", "kitchen", "temp"])
    }

    @Test func emptyPayloadDeletesAndPrunes() {
        let tree = TopicTree()
        tree.apply(msg("a/b/c", "1", retain: true))
        tree.apply(msg("a/x", "2", retain: true))
        tree.apply(msg("a/b/c", ""))
        #expect(tree.node(for: "a/b/c") == nil)
        #expect(tree.node(for: "a/b") == nil)
        #expect(tree.node(for: "a") != nil)
        #expect(tree.topicCount == 1)
        #expect(tree.node(for: "a")!.subtreeTopicCount == 1)
    }

    @Test func leadingSlashAndEmptyLevels() {
        let tree = TopicTree()
        tree.apply(msg("/x", "1"))
        tree.apply(msg("a//b", "2"))
        #expect(tree.node(for: "/x")?.name == "x")
        #expect(tree.node(for: "")?.name == "") // empty first level of "/x"
        #expect(tree.node(for: "a//b") != nil)
    }

    @Test func visibleRowsExpansionOrderAndFilter() {
        let tree = TopicTree()
        tree.apply(msg("b/one", "1"))
        tree.apply(msg("a/two", "2"))
        tree.apply(msg("a/three", "needle"))
        var options = TopicTree.ViewOptions()
        #expect(tree.visibleRows(options: options).map(\.id) == ["b", "a"])
        options.order = .alphabetical
        #expect(tree.visibleRows(options: options).map(\.id) == ["a", "b"])
        options.expanded = ["a"]
        #expect(tree.visibleRows(options: options).map(\.id) == ["a", "a/three", "a/two", "b"])
        options.autoExpand = .all
        options.expanded = []
        #expect(tree.visibleRows(options: options).count == 5)
        options.autoExpand = .off
        options.filter = "NEEDLE"
        #expect(tree.visibleRows(options: options).map(\.id) == ["a", "a/three"])
    }
}
