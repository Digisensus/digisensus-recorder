import Foundation
import GRDB
import Testing
@testable import DigisensusRecorder

struct SpeakerTests {
    private func recording(_ speakers: [Speaker]?) -> Recording {
        Recording(fileName: "rec.ogg", startedAt: Date(), autoStarted: false, format: "ogg", sizeBytes: 1,
                  transcriptStatus: .done, fileMissing: false, speakers: speakers)
    }

    private func them(_ speaker: Int?) -> TranscriptSegment {
        TranscriptSegment(recordingId: 1, channel: .them, speaker: speaker, startTime: 0, endTime: 1, text: "Labas")
    }

    @Test func otherSideSpeakersAreNumberedInTheOrderTheyFirstSpeak() async throws {
        let response: [String: Any] = ["dialogue": [
            ["speaker": "Agent", "start": 0.0, "end": 1.0, "text": "Hello everyone"],
            ["speaker": "speaker_2", "start": 1.2, "end": 2.0, "text": "Hi"],
            ["speaker": "speaker_0", "start": 2.1, "end": 3.0, "text": "Morning"],
            ["speaker": "speaker_2", "start": 3.1, "end": 4.0, "text": "Shall we start?"],
            ["speaker": "speaker_2", "start": 4.2, "end": 5.0, "text": "I have the numbers."],
            ["speaker": "Customer", "start": 5.2, "end": 5.5, "text": "Yes"],
        ]]
        let client = TranscriptionClient(settings: TranscriptionSettings())
        let result = try await client.finish(response, file: URL(fileURLWithPath: "/dev/null")) { _ in
            Issue.record("the server labelled speakers: no channel split expected"); return [:]
        }
        #expect(result.turns.map(\.channel) == [.me, .them, .them, .them])
        #expect(result.turns.map(\.speaker) == [nil, 0, 1, 0])
        #expect(result.turns[3].text == "Shall we start? I have the numbers. Yes")
    }

    @Test func wordsOutsideEverySpeakerGoToTheClosestOne() async throws {
        let response: [String: Any] = ["dialogue": [
            ["speaker": "speaker_0", "start": 0.0, "end": 4.0, "text": "We start in October."],
            ["speaker": "Customer", "start": 4.1, "end": 4.2, "text": "Mm"],
            ["speaker": "Customer", "start": 8.5, "end": 8.8, "text": "Well,"],
            ["speaker": "speaker_1", "start": 9.0, "end": 12.0, "text": "and the budget?"],
            ["speaker": "Agent", "start": 13.0, "end": 14.0, "text": "Approved."],
        ]]
        let client = TranscriptionClient(settings: TranscriptionSettings())
        let result = try await client.finish(response, file: URL(fileURLWithPath: "/dev/null")) { _ in [:] }
        #expect(result.turns.map(\.speaker) == [0, 1, nil])
        #expect(result.turns[1].text == "Well, and the budget?")
        #expect(result.turns.first?.text == "We start in October. Mm")
    }

    @Test func aCallWithoutSpeakerNumbersStaysUnnumbered() async throws {
        let response: [String: Any] = ["dialogue": [
            ["speaker": "Agent", "start": 0.0, "end": 1.0, "text": "Hello"],
            ["speaker": "Customer", "start": 1.5, "end": 2.0, "text": "Hi"],
        ]]
        let client = TranscriptionClient(settings: TranscriptionSettings())
        let result = try await client.finish(response, file: URL(fileURLWithPath: "/dev/null")) { _ in [:] }
        #expect(result.turns.map(\.speaker) == [nil, nil])
    }

    @Test func labelsUseNamesThenNumbersAndStayThemForASingleVoice() {
        let meeting = recording([Speaker(number: 0, name: "Anna", namedByYou: false),
                                 Speaker(number: 1, name: nil, namedByYou: false)])
        #expect(meeting.exportLabel(them(0), localized: false) == "Anna")
        #expect(meeting.exportLabel(them(1), localized: false) == "Speaker 2")
        #expect(meeting.exportLabel(them(nil), localized: false) == "Them")
        #expect(meeting.exportLabel(TranscriptSegment(recordingId: 1, channel: .me, startTime: 0, endTime: 1, text: "Hi"),
                                    localized: false) == "Me")
        #expect(meeting.speakerNumber(forLabel: "Speaker 2") == 1)
        #expect(meeting.speakerNumber(forLabel: "Speaker 3") == nil)
        #expect(meeting.speakerNumber(forLabel: "Them") == nil)

        let call = recording([Speaker(number: 0, name: nil, namedByYou: false)])
        #expect(call.exportLabel(them(0), localized: false) == "Them")
        #expect(call.speaker(of: them(0))?.number == 0)
        #expect(call.speakerNumber(forLabel: "Them") == 0)
        #expect(recording(nil).speaker(of: them(0)) == nil)
    }

    @Test func summaryReadsOnlyRealSpeakerNames() throws {
        let summary = try SummaryClient.parse(#"""
            {"headline": "Budget review.", "summary": "They went through the budget.",
             "speakers": {"Speaker 1": " Anna ", "Speaker 2": "unknown", "Them": "Speaker 3", "Speaker 4": null}}
            """#)
        #expect(summary.speakerNames == ["Speaker 1": "Anna"])
    }

    @Test func aiNamesFillInButNeverReplaceWhatYouTyped() throws {
        let database = try AppDatabase(DatabaseQueue())
        let id = try #require(try database.saveRecording(recording(nil)).id)
        try database.saveTranscript(recordingID: id, segments: [
            TranscriptSegment(recordingId: id, channel: .me, startTime: 0, endTime: 1, text: "Hello"),
            TranscriptSegment(recordingId: id, channel: .them, speaker: 0, startTime: 1, endTime: 2, text: "I'm Anna"),
            TranscriptSegment(recordingId: id, channel: .them, speaker: 1, startTime: 2, endTime: 3, text: "Tom here"),
        ], language: "en", model: "test")
        #expect(try database.recording(id: id)?.speakers?.map(\.number) == [0, 1])
        #expect(try database.segments(recordingID: id).map(\.speaker) == [nil, 0, 1])

        try database.setSpeakerName("Thomas", number: 1, recordingID: id)
        try database.saveSummary(CallSummary(headline: "Intro.", summary: "Intro.",
                                             speakerNames: ["Speaker 1": "Anna", "Speaker 2": "Tom"]),
                                 model: "test", recordingID: id)
        let named = try #require(try database.recording(id: id)?.speakers)
        #expect(named.map(\.name) == ["Anna", "Thomas"])
        #expect(named.map(\.namedByYou) == [false, true])

        try database.saveTranscript(recordingID: id, segments: [
            TranscriptSegment(recordingId: id, channel: .them, startTime: 0, endTime: 1, text: "Labas"),
        ], language: "lt", model: "test")
        #expect(try database.recording(id: id)?.speakers == nil)
    }
}
