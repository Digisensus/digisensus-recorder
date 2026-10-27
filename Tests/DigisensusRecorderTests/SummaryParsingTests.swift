import Foundation
import Testing
@testable import DigisensusRecorder

struct SummaryParsingTests {
    @Test func readsJSONWrappedInReasoningAndFences() throws {
        let answer = """
            <think>Let me think about this call.</think>
            ```json
            {"topic": "Invoice review.", "headline": "They agreed the invoice.", "summary": "Two sentences. Here.",
             "tags": ["#Work", "work", "Clients", "Extra"]}
            ```
            """
        let summary = try SummaryClient.parse(answer)
        #expect(summary.topic == "Invoice review")
        #expect(summary.headline == "They agreed the invoice.")
        #expect(summary.tags == ["Work", "Clients", "Extra"], "case-insensitively unique, hashes stripped, at most three")
    }

    @Test func fallsBackToProse() throws {
        let summary = try SummaryClient.parse("The call was about pricing. They will send a quote on Monday.")
        #expect(summary.headline == "The call was about pricing.")
        #expect(summary.summary.hasSuffix("on Monday."))
        #expect(summary.topic == nil)
    }

    @Test func rejectsHalfAJSONAnswer() {
        #expect(throws: SummaryError.self) { try SummaryClient.parse(#"{"topic": "Pricing", "headline": "They agreed"#) }
    }

    @Test func rejectsAnEmptyAnswer() {
        #expect(throws: SummaryError.self) { try SummaryClient.parse("<think>still thinking") }
    }

    @Test func readsAgreementsAndDropsTheUnusable() throws {
        let answer = """
            {"headline": "Pricing call.", "summary": "They agreed on a follow-up.", "agreements": [
             {"title": "Follow-up call with Acme", "kind": "Meeting", "owner": "both", "date": "2026-10-27",
              "time": "9:30", "duration_minutes": "45", "quote": "antradienį pusę dešimtos", "at": "12:41"},
             {"title": "Send the revised offer", "kind": "deadline", "owner": "you", "date": "2026-10-30",
              "time": null, "duration_minutes": 60, "quote": "", "at": 95},
             {"title": "Follow-up call with Acme", "date": "2026-10-27"},
             {"title": "Last week's call", "date": "2026-10-20"},
             {"title": "Impossible day", "date": "2026-02-30"},
             {"title": "", "date": "2026-11-02"},
             {"title": "Sometime", "date": "soon"}
            ]}
            """
        let recordedAt = try #require(Agreement.date(day: "2026-10-24"))
        let agreements = try SummaryClient.parse(answer, recordedAt: recordedAt).agreements
        #expect(agreements.count == 2)
        let call = try #require(agreements.first)
        #expect(call.kind == .meeting && call.owner == .both)
        #expect(call.time == "09:30" && call.durationMinutes == 45)
        #expect(call.atSeconds == 761)
        #expect(call.start == Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: try #require(Agreement.date(day: "2026-10-27"))))
        let offer = agreements[1]
        #expect(offer.isAllDay && offer.durationMinutes == nil, "a duration means nothing without a time")
        #expect(offer.quote == nil && offer.atSeconds == 95)
    }

    @Test func trustsTheWeekdayWhenTheModelMiscountsTheDate() throws {
        let answer = """
            {"headline": "Meeting planned.", "summary": "Next Wednesday at 17:30.", "agreements": [
             {"title": "Susitikimas per Google Meet", "date": "2026-11-03", "weekday": "Wednesday", "time": "17:30"},
             {"title": "Sutarties projektas", "date": "2026-11-06", "weekday": "Friday"},
             {"title": "Skambutis", "date": "2026-11-08", "weekday": "Monday"},
             {"title": "Ataskaita", "date": "2026-11-05", "weekday": "ketvirtadienis"}
            ]}
            """
        let recordedAt = try #require(Agreement.date(day: "2026-10-25"))
        let days = try SummaryClient.parse(answer, recordedAt: recordedAt).agreements.map(\.day)
        #expect(days == ["2026-11-04", "2026-11-06", "2026-11-02", "2026-11-05"],
                "moved within its Monday-to-Sunday week; an unknown weekday name leaves the date alone")
    }

    @Test func readsDecisionsAndActionsWithTheirDetails() throws {
        let answer = """
            {"headline": "Rollout planned.", "summary": "Two waves.",
             "decisions": [
              {"text": "Pilot starts with 8 reps", "comment": "Full rollout after a review.", "proposed_by": "them",
               "agreed_by": "Both", "topic": "Rollout", "at": "3:04"},
              {"text": "pilot starts with 8 reps", "comment": null},
              {"text": "  ", "comment": "nothing decided"}
             ],
             "actions": [
              {"text": "Send the CRM export sample", "owner": "You", "due": "by Friday", "topic": "CRM", "at": "1:02:41"},
              {"text": "Share the list of pilot users", "owner": "someone", "due": null}
             ]}
            """
        let summary = try SummaryClient.parse(answer)
        #expect(summary.decisions == [Decision(text: "Pilot starts with 8 reps", comment: "Full rollout after a review.",
                                               proposedBy: .them, agreedBy: .both, topic: "Rollout", atSeconds: 184)],
                "repeats and empty ones are dropped")
        #expect(summary.actions == [
            ActionItem(text: "Send the CRM export sample", owner: .you, due: "by Friday", topic: "CRM", atSeconds: 3761),
            ActionItem(text: "Share the list of pilot users"),
        ])
    }

    @Test func actionDueDatesFollowTheWeekdayAndSkipThePast() throws {
        let answer = """
            {"headline": "Tasks.", "summary": "Some tasks.", "actions": [
             {"text": "Send the offer", "due": "by Friday", "due_date": "2026-10-29", "due_weekday": "Friday"},
             {"text": "Fix the invoice", "due": "last week", "due_date": "2026-10-20"},
             {"text": "Call back", "due": "soon", "due_date": null}
            ]}
            """
        let recordedAt = try #require(Agreement.date(day: "2026-10-27"))
        let actions = try SummaryClient.parse(answer, recordedAt: recordedAt).actions
        #expect(actions.map(\.dueDate) == ["2026-10-30", nil, nil])
        #expect(actions.map(\.due) == ["by Friday", "last week", "soon"])
    }

    @Test func aSummaryWithoutAgreementsStillParses() throws {
        let summary = try SummaryClient.parse(#"{"headline": "Short call.", "summary": "Nothing agreed."}"#)
        #expect(summary.agreements.isEmpty)
    }

    @Test func givesTheModelTheCallDateAndTheDaysAfter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vilnius"))
        let recordedAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 14, minute: 5)))
        let context = SummaryClient.callDateContext(recordedAt, calendar: calendar)
        #expect(context.hasPrefix("The call was recorded on Saturday 2026-10-24 at 14:05."))
        #expect(context.contains("Sun 2026-10-25, Mon 2026-10-26"))
        #expect(context.hasSuffix("Sat 2026-11-14."))
    }
}
