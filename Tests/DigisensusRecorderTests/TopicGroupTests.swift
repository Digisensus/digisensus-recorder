import Testing
@testable import DigisensusRecorder

struct TopicGroupTests {
    private func actions(_ topics: [String?]) -> [ActionItem] {
        topics.enumerated().map { ActionItem(text: "Task \($0.offset)", owner: $0.offset.isMultiple(of: 2) ? .you : .them, topic: $0.element) }
    }

    @Test func aShortListIsNotSplitIntoTopics() {
        let groups = TopicGroup.grouping(actions(["Pricing", "Rollout", "Pricing"]), topic: \.topic)
        #expect(groups.count == 1 && groups[0].topic == nil && groups[0].entries.count == 3)
    }

    @Test func aLongListIsGroupedInTheOrderTopicsFirstCameUp() {
        let groups = TopicGroup.grouping(actions(["Rollout", "Pricing", "rollout", nil, "Pricing", "Rollout"]), topic: \.topic)
        #expect(groups.map(\.topic) == ["Rollout", "Pricing", "Other"])
        #expect(groups[0].entries.map(\.index) == [0, 2, 5], "topic names match without regard to case")
    }

    @Test func aTopicNamedOtherAndNoTopicStayApart() {
        let groups = TopicGroup.grouping(actions(["Other", nil, "Other", nil, "Pricing", nil]), topic: \.topic)
        #expect(Set(groups.map(\.id)).count == groups.count)
        #expect(groups.count == 3)
    }

    @Test func aFilterKeepsTheOriginalIndexes() {
        let groups = TopicGroup.grouping(actions(Array(repeating: nil, count: 8)), where: { $0.owner == .them }, topic: \.topic)
        #expect(groups.flatMap(\.entries).map(\.index) == [1, 3, 5, 7])
    }
}

struct DecisionTextTests {
    @Test func whoDecidedIsOneSentence() {
        #expect(Decision(text: "Go", proposedBy: .them, agreedBy: .both).whoDecided == "suggested by Them, agreed by Both")
        #expect(Decision(text: "Go", proposedBy: .you).whoDecided == "suggested by You")
        #expect(Decision(text: "Go", agreedBy: .them).whoDecided == "agreed by Them")
        #expect(Decision(text: "Go").whoDecided.isEmpty)
    }
}
