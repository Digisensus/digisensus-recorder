import Foundation
import GRDB
import Testing
@testable import DigisensusRecorder

struct AppDatabaseTests {
    private func database() throws -> (AppDatabase, id: Int64) {
        let database = try AppDatabase(DatabaseQueue())
        let recording = try database.saveRecording(Recording(
            fileName: "rec-2026-01-01_10-00-00-Zoom.ogg", startedAt: Date(), duration: 60, sourceLabel: "Zoom",
            sourceBundleID: "us.zoom.xos", autoStarted: true, format: "ogg", sizeBytes: 1000,
            transcriptStatus: .none, fileMissing: false))
        let id = try #require(recording.id)
        try database.saveTranscript(recordingID: id, segments: [
            TranscriptSegment(recordingId: id, channel: .them, startTime: 0, endTime: 4,
                              text: "Labas, ačiū kad prisijungei prie skambučio"),
            TranscriptSegment(recordingId: id, channel: .me, startTime: 4, endTime: 9,
                              text: "Sveiki, aptarkime sąskaitą faktūrą ir biudžetą"),
        ], language: "lt", model: "test")
        return (database, id)
    }

    @Test func savingTheSameFileAgainKeepsTheRow() throws {
        let (database, id) = try database()
        try database.setTitleAndNotes(title: "Kickoff", notes: nil, recordingID: id)
        let titled = try #require(try database.recording(id: id))

        var refreshed = titled
        refreshed.title = nil
        refreshed.sizeBytes = 2000
        let again = try database.saveRecording(refreshed)
        #expect(again.id == id)
        #expect(again.title == "Kickoff")
        #expect(again.sizeBytes == 2000)
    }

    @Test func editingTheTitleKeepsTheTranscriptStatus() throws {
        let (database, id) = try database()
        let before = try #require(try database.recording(id: id))
        try database.setTitleAndNotes(title: "Budget", notes: "Call back", recordingID: id)
        let after = try #require(try database.recording(id: id))
        #expect(after.title == "Budget" && after.notes == "Call back")
        #expect(after.transcriptStatus == before.transcriptStatus)
    }

    @Test func searchFoldsDiacriticsAndMatchesPrefixes() throws {
        let (database, _) = try database()
        let hits = try database.searchTranscripts("aciu")
        #expect(hits.count == 1)
        #expect(hits.first?.segment.channel == .them)
        #expect(hits.first?.snippet.contains("«ačiū»") == true)
        #expect(try database.searchTranscripts("biudz sask").count == 1)
        #expect(try database.searchTranscripts("nothing here").isEmpty)
    }

    @Test func deletingARecordingRemovesItsTranscript() throws {
        let (database, id) = try database()
        try database.deleteRecording(id: id)
        let leftovers = try database.writer.read { db in
            try TranscriptSegment.fetchCount(db) + (Int.fetchOne(db, sql: "SELECT count(*) FROM transcriptSegment_ft") ?? 0)
        }
        #expect(leftovers == 0)
    }

    @Test func aNewTranscriptClearsTheOldSummary() throws {
        let (database, id) = try database()
        try database.saveSummary(CallSummary(headline: "One", summary: "Two", topic: "Topic", tags: ["Work"]),
                                 model: "m", recordingID: id)
        #expect(try database.recording(id: id)?.summaryTopic == "Topic")
        try database.saveTranscript(recordingID: id, segments: [], language: nil, model: nil)
        let recording = try #require(try database.recording(id: id))
        #expect(recording.summaryShort == nil)
        #expect(recording.tags == ["Work"], "tags are the user's; they survive a new transcript")
    }

    @Test func aNewSummaryReplacesSuggestionsButKeepsWhatWasAdded() throws {
        let (database, id) = try database()
        func agreement(_ title: String, _ day: String) -> Agreement {
            Agreement(recordingId: 0, title: title, kind: .meeting, day: day)
        }
        try database.saveSummary(CallSummary(headline: "One", summary: "Two",
                                             agreements: [agreement("Demo", "2026-10-27"), agreement("Invoice", "2026-10-30")]),
                                 model: "m", recordingID: id)
        let first = try database.agreements(recordingID: id)
        #expect(first.map(\.title) == ["Demo", "Invoice"])
        #expect(first.allSatisfy { $0.recordingId == id && $0.status == .suggested })

        var demo = first[0]
        demo.time = "10:00"
        demo.status = .added
        try database.saveAgreement(demo)
        var invoice = first[1]
        invoice.status = .dismissed
        try database.saveAgreement(invoice)

        try database.saveSummary(CallSummary(headline: "One", summary: "Two",
                                             agreements: [agreement("demo", "2026-10-27"), agreement("Contract", "2026-11-03")]),
                                 model: "m", recordingID: id)
        let second = try database.agreements(recordingID: id)
        #expect(second.map(\.title) == ["Demo", "Contract"], "the added one stays once; the dismissed one goes")
        #expect(second[0].status == .added && second[0].time == "10:00")

        try database.saveTranscript(recordingID: id, segments: [], language: nil, model: nil)
        #expect(try database.agreements(recordingID: id).map(\.title) == ["Demo"])
        try database.deleteRecording(id: id)
        #expect(try database.agreements(recordingID: id).isEmpty)
    }

    @Test func tickedActionsStayTickedWhenTheSummaryIsRedone() throws {
        let (database, id) = try database()
        let first = CallSummary(headline: "One", summary: "Two", decisions: [Decision(text: "Go ahead")],
                                actions: [ActionItem(text: "Send the offer"), ActionItem(text: "Book a room")])
        try database.saveSummary(first, model: "m", recordingID: id)
        try database.setAction(at: 0, done: true, recordingID: id)
        try database.setAction(at: 7, done: true, recordingID: id)
        #expect(try database.recording(id: id)?.summaryActions?.map(\.done) == [true, false])

        let again = CallSummary(headline: "One", summary: "Two",
                                actions: [ActionItem(text: "Book a room"), ActionItem(text: "send the offer")])
        try database.saveSummary(again, model: "m", recordingID: id)
        let recording = try #require(try database.recording(id: id))
        #expect(recording.summaryActions?.map(\.done) == [false, true])
        #expect(recording.summaryDecisions == nil)
    }

    @Test func transcriptionJobsSurviveARelaunch() throws {
        let database = try AppDatabase(DatabaseQueue())
        let saved = try database.saveRecording(Recording(
            fileName: "rec-2026-01-02_10-00-00-Zoom.ogg", startedAt: Date(), duration: 1800, sourceLabel: "Zoom",
            sourceBundleID: "us.zoom.xos", autoStarted: true, format: "ogg", sizeBytes: 1000,
            transcriptStatus: .none, fileMissing: false))
        let id = try #require(saved.id)
        #expect(try database.pendingTranscriptions().isEmpty)

        let started = Date(timeIntervalSince1970: 1_800_000_000)
        try database.setTranscriptJob(id: "job-1", startedAt: started, recordingID: id)
        try database.setTranscriptJobPolls(42, recordingID: id)
        let pending = try database.pendingTranscriptions()
        #expect(pending.count == 1)
        #expect(pending[0].transcriptStatus == .pending)
        #expect(pending[0].transcriptJobID == "job-1")
        #expect(pending[0].transcriptJobStartedAt == started)
        #expect(pending[0].transcriptJobPolls == 42)

        try database.saveTranscript(recordingID: id, segments: [], language: "lt", model: "parakeet")
        let done = try #require(try database.recording(id: id))
        #expect(done.transcriptStatus == .done && done.transcriptJobID == nil && done.transcriptJobPolls == 0)
        try database.setTranscriptJob(id: "job-2", startedAt: started, recordingID: id)
        try database.setTranscriptStatus(.failed, recordingID: id)
        let failed = try #require(try database.recording(id: id))
        #expect(failed.transcriptJobID == nil && failed.transcriptJobStartedAt == nil)
        #expect(try database.pendingTranscriptions().isEmpty)
    }
}
