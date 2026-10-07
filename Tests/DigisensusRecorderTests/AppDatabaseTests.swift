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
        var titled = try #require(try database.recording(id: id))
        titled.title = "Kickoff"
        try database.update(titled)

        var refreshed = titled
        refreshed.title = nil
        refreshed.sizeBytes = 2000
        let again = try database.saveRecording(refreshed)
        #expect(again.id == id)
        #expect(again.title == "Kickoff")
        #expect(again.sizeBytes == 2000)
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
