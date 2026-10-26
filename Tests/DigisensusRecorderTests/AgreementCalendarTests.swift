import Foundation
import Testing
@testable import DigisensusRecorder

struct AgreementCalendarTests {
    private let stamp = Date(timeIntervalSince1970: 1_792_850_000)
    private let meeting = Agreement(recordingId: 1, title: "Call with Acme; pricing, v2", kind: .meeting,
                                    day: "2026-10-28", time: "17:30", durationMinutes: 45)
    private let deadline = Agreement(recordingId: 1, title: "Offer due", kind: .deadline, day: "2026-10-31")

    private func utc(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return formatter.string(from: date)
    }

    @Test func startKeepsTheClockTimeOnADaylightSavingDay() throws {
        let call = Agreement(recordingId: 1, title: "Call", kind: .meeting, day: "2026-10-25", time: "17:30")
        let start = try #require(call.start)
        let clock = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        #expect([clock.year, clock.month, clock.day, clock.hour, clock.minute] == [2026, 10, 25, 17, 30])
    }

    @Test func allDayEventsEndTheNextDay() throws {
        #expect(deadline.end == Calendar.current.date(byAdding: .day, value: 1, to: try #require(deadline.start)))
        #expect(try #require(meeting.end).timeIntervalSince(try #require(meeting.start)) == 45 * 60)
    }

    @Test func icsFilesAreEscapedAndUseUTCForTimedEvents() throws {
        let ics = try #require(meeting.icsFile(notes: "Line one\nLine two", uid: "u1", now: stamp))
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\n") && ics.hasSuffix("END:VCALENDAR\r\n"))
        #expect(ics.contains(#"SUMMARY:Call with Acme\; pricing\, v2"# + "\r\n"))
        #expect(ics.contains(#"DESCRIPTION:Line one\nLine two"# + "\r\n"))
        #expect(ics.contains("DTSTART:\(utc(try #require(meeting.start)))\r\n"))
        #expect(ics.contains("UID:u1@recorder.digisensus.com") && ics.contains("TRIGGER:-PT15M"))
    }

    @Test func icsAllDayEventsSpanOneDate() throws {
        let ics = try #require(deadline.icsFile(notes: "", uid: "u2", now: stamp))
        #expect(ics.contains("DTSTART;VALUE=DATE:20261031\r\n") && ics.contains("DTEND;VALUE=DATE:20261101\r\n"))
        #expect(ics.contains("TRIGGER:PT540M"))
    }

    @Test func icsLinesAreFoldedWithinSeventyFiveBytes() throws {
        let notes = String(repeating: "Susitarėme dėl sąskaitos ", count: 12)
        let ics = try #require(deadline.icsFile(notes: notes, uid: "u3", now: stamp))
        #expect(ics.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        #expect(ics.replacingOccurrences(of: "\r\n ", with: "").contains("DESCRIPTION:" + notes + "\r\n"))
    }

    @Test func googleLinksCarryUTCTimesOrAllDayDates() throws {
        let link = try #require(meeting.googleCalendarLink(notes: "a&b + c"))
        let items = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(link.host == "calendar.google.com")
        #expect(link.absoluteString.contains("details=a%26b%20%2B%20c"))
        #expect(items.first { $0.name == "dates" }?.value
                == utc(try #require(meeting.start)) + "/" + utc(try #require(meeting.end)))
        #expect(try #require(deadline.googleCalendarLink(notes: "")).absoluteString.contains("dates=20261031/20261101"))
    }

    @Test func outlookLinksUseTheGivenHost() throws {
        let link = try #require(deadline.outlookLink(host: "outlook.office.com", notes: ""))
        let items = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(link.host == "outlook.office.com")
        #expect(items.first { $0.name == "startdt" }?.value == "2026-10-31")
        #expect(items.first { $0.name == "allday" }?.value == "true")
    }
}
