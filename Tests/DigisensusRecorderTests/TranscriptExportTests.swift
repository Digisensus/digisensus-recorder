import Foundation
import Testing
@testable import DigisensusRecorder

struct TranscriptExportTests {
    private let export = TranscriptExport(
        recording: Recording(fileName: "rec-2026-10-25_09-21-41-Meet.ogg", startedAt: Date(timeIntervalSince1970: 1_792_920_000),
                             duration: 75, sourceLabel: "Meet", autoStarted: true, format: "ogg", sizeBytes: 1,
                             title: "Planning", transcriptStatus: .done, fileMissing: false, summaryLong: "Meeting next week."),
        segments: [
            TranscriptSegment(recordingId: 1, channel: .them, startTime: 1.25, endTime: 4, text: "Labas, kada susitinkam?"),
            TranscriptSegment(recordingId: 1, channel: .me, startTime: 65, endTime: 70.5, text: #"Trečiadienį 17:30, "Google Meet""#),
        ],
        agreements: [Agreement(recordingId: 1, title: "Susitikimas", kind: .meeting, day: "2026-11-04", time: "17:30")])

    @Test func plainTextHasTimesAndSpeakers() {
        let lines = export.render(.text).components(separatedBy: "\n")
        #expect(lines[0] == "Planning")
        #expect(lines.contains("[0:01] Them: Labas, kada susitinkam?"))
        #expect(lines.contains(#"[1:05] Me: Trečiadienį 17:30, "Google Meet""#))
    }

    @Test func csvQuotesFieldsAndStartsWithAByteOrderMark() {
        let csv = export.render(.csv)
        #expect(csv.hasPrefix("\u{FEFF}Time,Speaker,Text,Start seconds,End seconds\r\n"))
        #expect(csv.contains(#"0:01,Them,"Labas, kada susitinkam?",1.25,4.00"#))
        #expect(csv.contains(#"1:05,Me,"Trečiadienį 17:30, ""Google Meet""",65.00,70.50"#))
    }

    @Test func jsonCarriesTheCallAndItsTranscript() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(export.render(.json).utf8)) as? [String: Any])
        #expect(object["title"] as? String == "Planning")
        #expect(object["summary"] as? String == "Meeting next week.")
        #expect((object["transcript"] as? [[String: Any]])?.count == 2)
        #expect((object["agreements"] as? [[String: Any]])?.first?["date"] as? String == "2026-11-04")
    }

    @Test func subtitlesUseMillisecondClocks() {
        #expect(export.render(.srt).hasPrefix("1\n00:00:01,250 --> 00:00:04,000\nThem: Labas, kada susitinkam?\n"))
    }

    @Test func markdownListsWhatWasAgreed() {
        #expect(export.render(.markdown).contains("## Agreed\n\n- 2026-11-04 17:30: Susitikimas\n"))
    }

    @Test func formatNamesAcceptTheUsualSpellings() {
        #expect(TranscriptFormat(name: "MD") == .markdown && TranscriptFormat(name: "txt") == .text)
        #expect(TranscriptFormat(name: "docx") == nil)
    }
}
