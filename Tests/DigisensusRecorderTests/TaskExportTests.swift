import Foundation
import Testing
@testable import DigisensusRecorder

struct TaskExportTests {
    private let actions = [
        ActionItem(text: "Send the offer & price list", owner: .you, due: "by Friday", dueDate: "2026-10-30"),
        ActionItem(text: "Book a room", owner: .them),
    ]

    private func query(_ link: URL?, _ name: String) throws -> String {
        let link = try #require(link)
        return try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value)
    }

    @Test func thingsGetsEveryTaskWithItsDeadline() throws {
        let link = actions.thingsLink { "Note for \($0.text)" }
        #expect(link?.absoluteString.hasPrefix("things:///json?data=") == true)
        let data = Data(try query(link, "data").utf8)
        let todos = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let attributes = todos.compactMap { $0["attributes"] as? [String: Any] }
        #expect(todos.allSatisfy { $0["type"] as? String == "to-do" })
        #expect(attributes.map { $0["title"] as? String } == ["Send the offer & price list", "Book a room"])
        #expect(attributes.map { $0["deadline"] as? String } == ["2026-10-30", nil])
        #expect(attributes.first?["notes"] as? String == "Note for Send the offer & price list")
    }

    @Test func omniFocusGetsATaskPaperListInTheInbox() throws {
        let link = actions.omniFocusLink { _ in "From the call.\nDue soon." }
        #expect(link?.absoluteString.hasPrefix("omnifocus:///paste?") == true)
        #expect(try query(link, "target") == "inbox")
        #expect(try query(link, "content") == """
            - Send the offer & price list @due(2026-10-30)
            \tFrom the call.
            \tDue soon.
            - Book a room
            \tFrom the call.
            \tDue soon.
            """)
    }

    @Test func notesNameTheCallAndTheDueWording() {
        let recording = Recording(fileName: "rec.ogg", startedAt: Date(), autoStarted: false, format: "ogg", sizeBytes: 0,
                                  title: "Pilot planning", transcriptStatus: .done, fileMissing: false)
        let notes = actions[0].notes(from: recording)
        #expect(notes.contains("“Pilot planning”") && notes.hasSuffix("\nDue by Friday."))
        #expect(!actions[1].notes(from: recording).contains("Due"))
    }
}
