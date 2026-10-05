import Testing
@testable import DigisensusRecorder

struct SummaryParsingTests {
    @Test func readsJSONWrappedInReasoningAndFences() throws {
        let answer = """
            <think>Let me think about this call.</think>
            ```json
            {"topic": "Invoice review.", "headline": "They agreed the invoice.", "summary": "Two sentences. Here.",
             "points": ["You: send the invoice", ""], "tags": ["#Work", "work", "Clients", "Extra"]}
            ```
            """
        let summary = try SummaryClient.parse(answer)
        #expect(summary.topic == "Invoice review")
        #expect(summary.headline == "They agreed the invoice.")
        #expect(summary.points == ["You: send the invoice"])
        #expect(summary.tags == ["Work", "Clients", "Extra"], "case-insensitively unique, hashes stripped, at most three")
    }

    @Test func fallsBackToProse() throws {
        let summary = try SummaryClient.parse("The call was about pricing. They will send a quote on Monday.")
        #expect(summary.headline == "The call was about pricing.")
        #expect(summary.summary.hasSuffix("on Monday."))
        #expect(summary.topic == nil)
    }

    @Test func rejectsAnEmptyAnswer() {
        #expect(throws: SummaryError.self) { try SummaryClient.parse("<think>still thinking") }
    }
}
