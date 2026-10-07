import Foundation
import GRDB

struct Recording: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    enum TranscriptStatus: String, Codable {
        case none, pending, done, failed
    }

    var id: Int64?
    var fileName: String
    var startedAt: Date
    var duration: Double?
    var sourceLabel: String?
    var sourceBundleID: String?
    var autoStarted: Bool
    var format: String
    var sizeBytes: Int64
    var title: String?
    var notes: String?
    var transcriptStatus: TranscriptStatus
    var transcriptLanguage: String?
    var transcriptModel: String?
    var fileMissing: Bool
    var summaryShort: String?
    var summaryLong: String?
    var summaryModel: String?
    var summaryTopic: String?
    var summaryPoints: [String]?
    var tags: [String] = []
    var transcriptJobID: String?
    var transcriptJobStartedAt: Date?
    var transcriptJobPolls: Int = 0

    static let databaseTableName = "recording"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TranscriptSegment: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    enum Channel: Int, Codable {
        case them = 0, me = 1
    }

    var id: Int64?
    var recordingId: Int64
    var channel: Channel
    var startTime: Double
    var endTime: Double
    var text: String
    var confidence: Double?

    static let databaseTableName = "transcriptSegment"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TranscriptSearchHit: Identifiable {
    var segment: TranscriptSegment
    var recording: Recording
    var snippet: String
    var id: Int64 { segment.id ?? 0 }
}

final class AppDatabase {
    static let shared: AppDatabase = {
        do {
            let folder = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Digisensus Recorder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try AppDatabase(DatabasePool(path: folder.appendingPathComponent("recorder.sqlite").path))
        } catch {
            Log.write("database unavailable, using memory: \(error)")
            return try! AppDatabase(DatabaseQueue())
        }
    }()

    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1 recordings, transcripts, embeddings") { db in
            try db.create(table: "recording") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileName", .text).notNull().unique()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("duration", .double)
                t.column("sourceLabel", .text)
                t.column("sourceBundleID", .text)
                t.column("autoStarted", .boolean).notNull().defaults(to: false)
                t.column("format", .text).notNull()
                t.column("sizeBytes", .integer).notNull().defaults(to: 0)
                t.column("title", .text)
                t.column("notes", .text)
                t.column("transcriptStatus", .text).notNull().defaults(to: "none")
                t.column("transcriptLanguage", .text)
                t.column("transcriptModel", .text)
                t.column("fileMissing", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "transcriptSegment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("recording", onDelete: .cascade).notNull()
                t.column("channel", .integer).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("text", .text).notNull()
                t.column("confidence", .double)
            }
            try db.create(index: "transcriptSegment_timeline", on: "transcriptSegment",
                          columns: ["recordingId", "startTime"])

            try db.create(virtualTable: "transcriptSegment_ft", using: FTS5()) { t in
                t.synchronize(withTable: "transcriptSegment")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("text")
            }

            try db.create(table: "transcriptEmbedding") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("recording", onDelete: .cascade).notNull()
                t.column("startSegmentId", .integer).references("transcriptSegment", onDelete: .setNull)
                t.column("endSegmentId", .integer).references("transcriptSegment", onDelete: .setNull)
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("text", .text).notNull()
                t.column("model", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("vector", .blob).notNull()
            }
            try db.create(index: "transcriptEmbedding_model", on: "transcriptEmbedding",
                          columns: ["model", "recordingId"])
        }

        migrator.registerMigration("v2 call summaries") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "summaryShort", .text)
                t.add(column: "summaryLong", .text)
                t.add(column: "summaryModel", .text)
            }
        }

        migrator.registerMigration("v3 topics, points and tags") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "summaryTopic", .text)
                t.add(column: "summaryPoints", .jsonText)
                t.add(column: "tags", .jsonText).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v4 transcription jobs") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "transcriptJobID", .text)
                t.add(column: "transcriptJobStartedAt", .datetime)
                t.add(column: "transcriptJobPolls", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}

extension AppDatabase {
    @discardableResult
    func saveRecording(_ recording: Recording) throws -> Recording {
        try writer.write { db in
            var recording = recording
            if var existing = try Recording.filter(Column("fileName") == recording.fileName).fetchOne(db) {
                existing.sizeBytes = recording.sizeBytes
                existing.duration = recording.duration ?? existing.duration
                existing.fileMissing = false
                if existing.notes == nil { existing.notes = recording.notes }
                try existing.update(db)
                return existing
            }
            try recording.insert(db)
            return recording
        }
    }

    func update(_ recording: Recording) throws {
        try writer.write { try recording.update($0) }
    }

    func deleteRecording(id: Int64) throws {
        _ = try writer.write { try Recording.deleteOne($0, key: id) }
    }

    func recording(fileName: String) throws -> Recording? {
        try writer.read { try Recording.filter(Column("fileName") == fileName).fetchOne($0) }
    }

    func recording(id: Int64) throws -> Recording? {
        try writer.read { try Recording.fetchOne($0, key: id) }
    }

    func knownFileNames() throws -> Set<String> {
        try writer.read { try Set(String.fetchAll($0, Recording.select(Column("fileName")))) }
    }

    func markMissing(except present: Set<String>) throws {
        try writer.write { db in
            for var recording in try Recording.fetchAll(db) {
                let missing = !present.contains(recording.fileName)
                if recording.fileMissing != missing {
                    recording.fileMissing = missing
                    try recording.update(db)
                }
            }
        }
    }

    func recordingsObservation() -> ValueObservation<ValueReducers.Fetch<[Recording]>> {
        ValueObservation.tracking { db in
            try Recording.filter(Column("fileMissing") == false).order(Column("startedAt").desc).fetchAll(db)
        }
    }
}

extension AppDatabase {
    func saveTranscript(recordingID: Int64, segments: [TranscriptSegment], language: String?, model: String?) throws {
        try writer.write { db in
            try TranscriptSegment.filter(Column("recordingId") == recordingID).deleteAll(db)
            for var segment in segments {
                segment.recordingId = recordingID
                try segment.insert(db)
            }
            if var recording = try Recording.fetchOne(db, key: recordingID) {
                recording.transcriptStatus = .done
                recording.transcriptLanguage = language
                recording.transcriptModel = model
                recording.transcriptJobID = nil
                recording.transcriptJobStartedAt = nil
                recording.transcriptJobPolls = 0
                recording.summaryShort = nil
                recording.summaryLong = nil
                recording.summaryModel = nil
                recording.summaryTopic = nil
                recording.summaryPoints = nil
                try recording.update(db)
            }
        }
    }

    func saveSummary(_ summary: CallSummary, model: String, recordingID: Int64) throws {
        try writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: recordingID) else { return }
            recording.summaryShort = summary.headline
            recording.summaryLong = summary.summary
            recording.summaryModel = model
            recording.summaryTopic = summary.topic
            recording.summaryPoints = summary.points.isEmpty ? nil : summary.points
            if recording.tags.isEmpty { recording.tags = Array(summary.tags.prefix(3)) }
            try recording.update(db)
        }
    }

    func setTags(_ tags: [String], recordingID: Int64) throws {
        try writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: recordingID) else { return }
            recording.tags = tags
            try recording.update(db)
        }
    }

    func setTranscriptStatus(_ status: Recording.TranscriptStatus, recordingID: Int64) throws {
        try writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: recordingID) else { return }
            recording.transcriptStatus = status
            if status != .pending {
                recording.transcriptJobID = nil
                recording.transcriptJobStartedAt = nil
                recording.transcriptJobPolls = 0
            }
            try recording.update(db)
        }
    }

    func setTranscriptJob(id jobID: String, startedAt: Date, recordingID: Int64) throws {
        try writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: recordingID) else { return }
            recording.transcriptStatus = .pending
            recording.transcriptJobID = jobID
            recording.transcriptJobStartedAt = startedAt
            recording.transcriptJobPolls = 0
            try recording.update(db)
        }
    }

    func setTranscriptJobPolls(_ polls: Int, recordingID: Int64) throws {
        try writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: recordingID) else { return }
            recording.transcriptJobPolls = polls
            try recording.update(db)
        }
    }

    func pendingTranscriptions() throws -> [Recording] {
        try writer.read { db in
            try Recording.filter(Column("transcriptStatus") == Recording.TranscriptStatus.pending.rawValue)
                .order(Column("startedAt")).fetchAll(db)
        }
    }

    func segments(recordingID: Int64) throws -> [TranscriptSegment] {
        try writer.read { db in
            try TranscriptSegment.filter(Column("recordingId") == recordingID).order(Column("startTime")).fetchAll(db)
        }
    }

    func searchTranscripts(_ query: String, limit: Int = 50) throws -> [TranscriptSearchHit] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try writer.read { db in
            let segmentColumns = try db.columns(in: "transcriptSegment").count
            let recordingColumns = try db.columns(in: "recording").count
            let rows = try Row.fetchAll(db, sql: """
                SELECT transcriptSegment.*, recording.*,
                       snippet(transcriptSegment_ft, 0, '«', '»', '…', 12) AS snippet
                FROM transcriptSegment_ft
                JOIN transcriptSegment ON transcriptSegment.id = transcriptSegment_ft.rowid
                JOIN recording ON recording.id = transcriptSegment.recordingId
                WHERE transcriptSegment_ft MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [pattern, limit],
                adapter: ScopeAdapter([
                    "segment": RangeRowAdapter(0..<segmentColumns),
                    "recording": RangeRowAdapter(segmentColumns..<segmentColumns + recordingColumns),
                ]))
            return try rows.map { row in
                TranscriptSearchHit(segment: try TranscriptSegment(row: row.scopes["segment"]!),
                                    recording: try Recording(row: row.scopes["recording"]!),
                                    snippet: row["snippet"])
            }
        }
    }
}
