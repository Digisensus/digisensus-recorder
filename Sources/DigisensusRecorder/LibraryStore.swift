import AppKit
import AVFoundation
import GRDB

/// The recordings library as the UI sees it: a live list from the database, kept in step
/// with the recordings folder.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published var searchText = "" {
        didSet { runSearch() }
    }
    @Published private(set) var searchHits: [TranscriptSearchHit] = []
    /// The recording selected in the library window.
    @Published var selection: Int64?
    /// Set to ask the user to confirm deleting this recording.
    @Published var pendingDeletion: Recording?

    // Browsing: a day or everything, narrowed by source and tag filters.
    enum ListMode { case day, all }
    @Published var listMode = ListMode.day
    /// First day of the month the calendar shows.
    @Published private(set) var calendarMonth = LibraryStore.startOfMonth(Date())
    /// Start of the day listed in day mode.
    @Published private(set) var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Source labels ("Zoom", "Phone", "Manual") to show; empty shows all.
    @Published var sourceFilter: Set<String> = []
    /// Tags to show; a call matches when it has any of them. Empty shows all.
    @Published var tagFilter: Set<String> = []

    var isFiltering: Bool { !sourceFilter.isEmpty || !tagFilter.isEmpty }

    func passesFilters(_ recording: Recording) -> Bool {
        (sourceFilter.isEmpty || sourceFilter.contains(recording.sourceKey))
            && (tagFilter.isEmpty || recording.tags.contains(where: tagFilter.contains))
    }

    var filteredRecordings: [Recording] { recordings.filter(passesFilters) }

    /// What the list shows: the selected day's calls, or all of them, after the filters.
    var listedRecordings: [Recording] {
        let filtered = filteredRecordings
        guard listMode == .day else { return filtered }
        return filtered.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: selectedDay) }
    }

    /// Shows a day and selects its first call.
    func select(day: Date) {
        listMode = .day
        selectedDay = Calendar.current.startOfDay(for: day)
        showMonth(containing: day)
        selection = listedRecordings.first?.id
    }

    func showAll() {
        listMode = .all
        if selection == nil || !filteredRecordings.contains(where: { $0.id == selection }) {
            selection = filteredRecordings.first?.id
        }
    }

    /// Opens on today, or on the last day with calls when today has none yet.
    func showLatestDay() {
        let today = Date()
        let hasToday = recordings.contains { Calendar.current.isDateInToday($0.startedAt) }
        select(day: hasToday ? today : recordings.first?.startedAt ?? today)
    }

    func clearFilters() {
        sourceFilter = []
        tagFilter = []
    }

    func shiftMonth(by months: Int) {
        if let month = Calendar.current.date(byAdding: .month, value: months, to: calendarMonth) {
            calendarMonth = month
        }
    }

    func showMonth(containing date: Date) {
        calendarMonth = Self.startOfMonth(date)
    }

    private static func startOfMonth(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    // Tags

    /// Every tag in the archive, most used first.
    var allTags: [String] {
        var counts: [String: Int] = [:]
        for recording in recordings {
            for tag in recording.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    func addTag(_ tag: String, to recording: Recording) {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !recording.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        // Reuse the spelling already in the archive, so "work" joins "Work".
        let existing = allTags.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
        setTags(recording.tags + [existing ?? tag], of: recording)
    }

    func removeTag(_ tag: String, from recording: Recording) {
        setTags(recording.tags.filter { $0 != tag }, of: recording)
    }

    private func setTags(_ tags: [String], of recording: Recording) {
        guard let id = recording.id else { return }
        do {
            try database.setTags(tags, recordingID: id)
        } catch {
            Log.write("could not tag \(recording.fileName): \(error)")
        }
    }

    // AI

    /// Who transcribes and summarises. One choice covers both; the per-step providers
    /// follow it.
    @Published var aiService = LibraryStore.loadAIService() {
        didSet {
            UserDefaults.standard.set(aiService.rawValue, forKey: "aiService")
            applyAIService()
        }
    }

    private func applyAIService() {
        let provider: AIProvider
        switch aiService {
        case .digisensus: provider = .digisensus
        case .own: provider = .custom
        case .off: return
        }
        if transcription.provider != provider { transcription.provider = provider }
        if summary.provider != provider { summary.provider = provider }
    }

    /// Transcribe, summarise and tag every new recording: one switch for both steps.
    var autoProcess: Bool {
        get { autoTranscribe && autoSummarize }
        set {
            autoTranscribe = newValue
            autoSummarize = newValue
        }
    }

    private static func loadAIService() -> AIService {
        UserDefaults.standard.string(forKey: "aiService").flatMap(AIService.init(rawValue:)) ?? .digisensus
    }

    // Transcription
    @Published var transcription = LibraryStore.loadTranscriptionSettings() {
        didSet { saveTranscriptionSettings(keyChanged: transcription.apiKey != oldValue.apiKey) }
    }
    /// Send every finished recording to the transcription server.
    @Published var autoTranscribe = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    @Published private(set) var transcribing: Set<Int64> = []
    @Published private(set) var transcriptionErrors: [Int64: String] = [:]
    /// Bumped whenever a transcript is saved, so open detail views reload theirs.
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var connectionStatus: String?

    // Summaries
    @Published var summary = LibraryStore.loadSummarySettings() {
        didSet { saveSummarySettings(keyChanged: summary.apiKey != oldValue.apiKey) }
    }
    /// Summarise every transcript as soon as it arrives.
    @Published var autoSummarize = UserDefaults.standard.object(forKey: "autoSummarize") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSummarize, forKey: "autoSummarize") }
    }
    @Published private(set) var summarizing: Set<Int64> = []
    @Published private(set) var summaryErrors: [Int64: String] = [:]
    @Published private(set) var summaryConnectionStatus: String?

    /// The Digisensus account used by the Digisensus provider.
    let account = DigisensusAccount()

    let folder: URL
    private let database: AppDatabase
    private var observation: AnyDatabaseCancellable?

    init(folder: URL, database: AppDatabase = .shared) {
        self.folder = folder
        self.database = database
        observation = database.recordingsObservation().start(
            in: database.writer, scheduling: .immediate,
            onError: { Log.write("recordings observation failed: \($0)") },
            onChange: { [weak self] recordings in
                MainActor.assumeIsolated { self?.recordings = recordings }
            })
        syncFolder()
    }

    func url(for recording: Recording) -> URL {
        folder.appendingPathComponent(recording.fileName)
    }

    // MARK: Indexing

    /// Records a recording the app just finished, with everything it knows about it.
    func register(file: URL, startedAt: Date, duration: Double, call: DetectedCall?, notes: String? = nil) {
        var bundleID: String?
        if case .application(let id) = call?.source { bundleID = id }
        let recording = Recording(
            fileName: file.lastPathComponent, startedAt: startedAt, duration: duration,
            sourceLabel: call?.label, sourceBundleID: bundleID, autoStarted: call != nil,
            format: RecordingFile.fileExtension, sizeBytes: Self.size(of: file), notes: notes,
            transcriptStatus: .none, fileMissing: false)
        do {
            let saved = try database.saveRecording(recording)
            // Digisensus without an account: leave it for the user to transcribe after signing in.
            if autoTranscribe, aiService != .off, transcriptionSettings() != nil { transcribe(saved) }
        } catch {
            Log.write("could not index \(file.lastPathComponent): \(error)")
        }
    }

    // MARK: Transcription

    /// `summarizeAfter` overrides the automatic setting for the summary that follows.
    func transcribe(_ recording: Recording, summarizeAfter: Bool? = nil) {
        guard let id = recording.id, !transcribing.contains(id) else { return }
        guard aiService != .off else {
            transcriptionErrors[id] = Self.aiIsOff
            return
        }
        guard let settings = transcriptionSettings() else {
            transcriptionErrors[id] = Self.signInNeeded
            return
        }
        if settings.provider == .digisensus, let block = account.spendingBlock {
            transcriptionErrors[id] = block
            return
        }
        transcribing.insert(id)
        transcriptionErrors[id] = nil
        try? database.setTranscriptStatus(.pending, recordingID: id)

        let client = TranscriptionClient(settings: settings)
        let file = url(for: recording)
        let model = settings.model
        Task {
            do {
                let started = Date()
                let result = try await client.transcribe(file)
                let segments = result.turns.map {
                    TranscriptSegment(recordingId: id, channel: $0.channel, startTime: $0.start,
                                      endTime: $0.end, text: $0.text)
                }
                try database.saveTranscript(recordingID: id, segments: segments,
                                            language: result.language, model: model)
                Log.write(String(format: "transcribed %@: %d turns in %.1f s", recording.fileName,
                                 segments.count, Date().timeIntervalSince(started)))
                if summarizeAfter ?? autoSummarize, aiService != .off, !segments.isEmpty, summarySettings() != nil {
                    summarize(recording)
                }
            } catch {
                try? database.setTranscriptStatus(.failed, recordingID: id)
                transcriptionErrors[id] = error.localizedDescription
                Log.write("transcription of \(recording.fileName) failed: \(error)")
            }
            transcribing.remove(id)
            transcriptRevision += 1
            if settings.provider == .digisensus { await account.refresh() } // credit changed
        }
    }

    // MARK: Summaries

    func summarize(_ recording: Recording) {
        guard let id = recording.id, !summarizing.contains(id) else { return }
        let segments = (try? database.segments(recordingID: id)) ?? []
        guard !segments.isEmpty else {
            summaryErrors[id] = "Transcribe the recording first; the summary is made from the transcript."
            return
        }
        guard aiService != .off else {
            summaryErrors[id] = Self.aiIsOff
            return
        }
        guard let settings = summarySettings() else {
            summaryErrors[id] = Self.signInNeeded
            return
        }
        if settings.provider == .digisensus, let block = account.spendingBlock {
            summaryErrors[id] = block
            return
        }
        summarizing.insert(id)
        summaryErrors[id] = nil

        let client = SummaryClient(settings: settings)
        let model = settings.model
        let knownTags = allTags
        Task {
            do {
                let started = Date()
                let result = try await client.summarize(segments, knownTags: knownTags)
                try database.saveSummary(result, model: model, recordingID: id)
                Log.write(String(format: "summarised %@ in %.1f s", recording.fileName, Date().timeIntervalSince(started)))
            } catch {
                summaryErrors[id] = error.localizedDescription
                Log.write("summary of \(recording.fileName) failed: \(error)")
            }
            summarizing.remove(id)
            if settings.provider == .digisensus { await account.refresh() }
        }
    }

    func checkSummaryConnection() {
        guard let settings = summarySettings() else {
            summaryConnectionStatus = Self.signInNeeded
            return
        }
        summaryConnectionStatus = "Checking…"
        let client = SummaryClient(settings: settings)
        Task { summaryConnectionStatus = await client.checkConnection() }
    }

    func checkConnection() {
        guard let settings = transcriptionSettings() else {
            connectionStatus = Self.signInNeeded
            return
        }
        connectionStatus = "Checking…"
        let client = TranscriptionClient(settings: settings)
        Task { connectionStatus = await client.checkConnection() }
    }

    // MARK: Providers

    private static let signInNeeded = "Sign in to Digisensus in Settings › Transcription & AI, or choose your own service."
    private static let aiIsOff = "Transcription is off. Choose a service in Settings › Transcription & AI."

    /// What the transcription client should use: the settings as entered for an own server,
    /// or the Digisensus service with this Mac's token. nil when Digisensus needs a sign-in.
    func transcriptionSettings() -> TranscriptionSettings? {
        var settings = transcription
        guard settings.provider == .digisensus else { return settings }
        guard let token = account.deviceToken else { return nil }
        settings.server = DigisensusAccount.server.absoluteString
        settings.apiKey = token
        settings.model = account.model(for: "transcription", fallback: "whisper-lt")
        return settings
    }

    func summarySettings() -> SummarySettings? {
        var settings = summary
        guard settings.provider == .digisensus else { return settings }
        guard let token = account.deviceToken else { return nil }
        settings.server = DigisensusAccount.server.absoluteString
        settings.apiKey = token
        settings.model = account.model(for: "chat", fallback: "chat-lt")
        return settings
    }

    private static func provider(forKey key: String) -> AIProvider {
        UserDefaults.standard.string(forKey: key).flatMap(AIProvider.init(rawValue:)) ?? .digisensus
    }

    private static func loadSummarySettings() -> SummarySettings {
        let defaults = UserDefaults.standard
        var settings = SummarySettings()
        settings.provider = provider(forKey: "summaryProvider")
        settings.server = defaults.string(forKey: "summaryServer") ?? settings.server
        settings.apiKey = Keychain.string("summary-api-key") ?? ""
        settings.model = defaults.string(forKey: "summaryModel") ?? settings.model
        return settings
    }

    private func saveSummarySettings(keyChanged: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(summary.provider.rawValue, forKey: "summaryProvider")
        defaults.set(summary.server, forKey: "summaryServer")
        defaults.set(summary.model, forKey: "summaryModel")
        if keyChanged { Keychain.set(summary.apiKey, for: "summary-api-key") }
    }

    private static func loadTranscriptionSettings() -> TranscriptionSettings {
        let defaults = UserDefaults.standard
        var settings = TranscriptionSettings()
        settings.provider = provider(forKey: "transcriptionProvider")
        settings.server = defaults.string(forKey: "transcriptionServer") ?? settings.server
        settings.apiKey = Keychain.string("transcription-api-key") ?? ""
        settings.model = defaults.string(forKey: "transcriptionModel") ?? settings.model
        settings.language = defaults.string(forKey: "transcriptionLanguage") ?? ""
        return settings
    }

    private func saveTranscriptionSettings(keyChanged: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(transcription.provider.rawValue, forKey: "transcriptionProvider")
        defaults.set(transcription.server, forKey: "transcriptionServer")
        defaults.set(transcription.model, forKey: "transcriptionModel")
        defaults.set(transcription.language, forKey: "transcriptionLanguage")
        if keyChanged { Keychain.set(transcription.apiKey, for: "transcription-api-key") }
    }

    /// Indexes audio files the database doesn't know (made before the library existed, or
    /// copied in) and flags rows whose file has gone.
    func syncFolder() {
        let folder = folder
        let database = database
        Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]) else { return }
            // Recordings are Ogg Opus; captures still being recorded (or recovered) are not.
            let audio = files.filter { $0.pathExtension.lowercased() == RecordingFile.fileExtension }
            do {
                let known = try database.knownFileNames()
                for file in audio where !known.contains(file.lastPathComponent) {
                    try database.saveRecording(Self.describe(file))
                    try? FileManager.default.removeItem(at: RecordingFile.notesURL(for: file))
                }
                try database.markMissing(except: Set(audio.map(\.lastPathComponent)))
            } catch {
                Log.write("folder sync failed: \(error)")
            }
        }
    }

    /// Reads these files again: new ones are added, known ones get their size and length
    /// refreshed (title, notes and transcript stay).
    func reindex(_ files: [URL]) {
        let database = database
        Task.detached(priority: .utility) {
            for file in files {
                do {
                    try database.saveRecording(Self.describe(file))
                    try? FileManager.default.removeItem(at: RecordingFile.notesURL(for: file))
                } catch {
                    Log.write("could not reindex \(file.lastPathComponent): \(error)")
                }
            }
        }
    }

    /// Reads what it can from the file itself: "rec-2026-09-21_14-22-25-Zoom.ogg".
    private nonisolated static func describe(_ file: URL) -> Recording {
        let name = file.deletingPathExtension().lastPathComponent
        var startedAt = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var label: String?
        if let match = name.wholeMatch(of: #/rec-(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(?:-(.+))?/#) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            startedAt = formatter.date(from: String(match.1)) ?? startedAt
            label = match.2.map(String.init)
        }
        return Recording(
            fileName: file.lastPathComponent, startedAt: startedAt, duration: OggOpusDecoder.duration(of: file),
            sourceLabel: label, sourceBundleID: nil, autoStarted: label != nil,
            format: file.pathExtension.lowercased(), sizeBytes: size(of: file),
            notes: try? String(contentsOf: RecordingFile.notesURL(for: file), encoding: .utf8),
            transcriptStatus: .none, fileMissing: false)
    }

    private nonisolated static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: Lookups

    /// A saved recording by its id, whether or not its file is present.
    func recording(id: Int64) -> Recording? {
        try? database.recording(id: id)
    }

    /// Straight from the database, for a recording saved a moment ago: the published list
    /// catches up shortly after.
    func recording(fileName: String) -> Recording? {
        try? database.recording(fileName: fileName)
    }

    func segments(of recording: Recording) -> [TranscriptSegment] {
        guard let id = recording.id else { return [] }
        return (try? database.segments(recordingID: id)) ?? []
    }

    func searchTranscripts(_ query: String, limit: Int) -> [TranscriptSearchHit] {
        (try? database.searchTranscripts(query, limit: limit)) ?? []
    }

    // MARK: Actions

    func play(_ recording: Recording) {
        NSWorkspace.shared.open(url(for: recording))
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: recording)])
    }

    func save(_ recording: Recording) {
        do {
            try database.update(recording)
        } catch {
            Log.write("could not save \(recording.fileName): \(error)")
        }
    }

    /// Deletes the recording the user just confirmed, and selects its neighbour so the
    /// detail pane doesn't go blank.
    func deletePending() {
        guard let recording = pendingDeletion else { return }
        pendingDeletion = nil
        if selection == recording.id {
            let visible = listedRecordings
            let index = visible.firstIndex { $0.id == recording.id }
            let neighbour = index.flatMap { $0 + 1 < visible.count ? visible[$0 + 1] : $0 > 0 ? visible[$0 - 1] : nil }
            selection = neighbour?.id
        }
        trash(recording)
    }

    /// Moves the audio to the Trash and removes the row with its transcript.
    func trash(_ recording: Recording) {
        guard let id = recording.id else { return }
        do {
            let file = url(for: recording)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            }
            try database.deleteRecording(id: id)
        } catch {
            Log.write("could not trash \(recording.fileName): \(error)")
        }
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        searchHits = query.isEmpty ? [] : searchTranscripts(query, limit: 50)
    }

    struct SearchResult: Identifiable {
        let recording: Recording
        /// The matching transcript line, «hit» marked, when the match was in the transcript.
        let snippet: String?
        var id: Int64 { recording.rowID }
    }

    /// Calls whose name, summary, tags or notes match the search, and calls whose
    /// transcript does, newest first and filtered like the list.
    var searchResults: [SearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let words = query.split(separator: " ").map(String.init)
        var snippets: [Int64: String] = [:]
        for hit in searchHits where snippets[hit.recording.rowID] == nil {
            snippets[hit.recording.rowID] = hit.snippet
        }
        return filteredRecordings.compactMap { recording in
            let text = [recording.heading, recording.channelName, recording.summaryShort ?? "",
                        recording.summaryLong ?? "", recording.notes ?? "", recording.tags.joined(separator: " ")]
                .joined(separator: " ")
            let snippet = snippets[recording.rowID]
            guard snippet != nil || words.allSatisfy(text.localizedStandardContains) else { return nil }
            return SearchResult(recording: recording, snippet: snippet)
        }
    }
}

/// Who transcribes and summarises calls.
enum AIService: String, CaseIterable, Identifiable {
    case digisensus, own, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .digisensus: return "Digisensus"
        case .own: return "Own service"
        case .off: return "Off"
        }
    }
}

extension Recording {
    /// `id` without the optional, for list rows and selection. Saved recordings always have one.
    var rowID: Int64 { id ?? -1 }

    /// What the call is called in lists: its channel, like "Zoom call" or "Phone call".
    var channelName: String { Self.channelName(for: sourceLabel) }

    static func channelName(for sourceLabel: String?) -> String {
        switch sourceLabel {
        case nil: return "Recording"
        case "Phone": return "Phone call"
        case "Meet": return "Google Meet call"
        case let label?: return "\(label) call"
        }
    }

    /// The source filter it falls under.
    var sourceKey: String { sourceLabel ?? "Manual" }

    var isPhoneCall: Bool { sourceLabel == "Phone" }

    /// The name you gave it, else the topic from its summary, else the channel.
    var heading: String {
        if let title, !title.isEmpty { return title }
        if let summaryTopic, !summaryTopic.isEmpty { return summaryTopic }
        return channelName
    }

    /// The name you gave it, else the channel: for lists, where the summary's headline is
    /// shown underneath and would repeat the topic.
    var titleOrChannel: String {
        if let title, !title.isEmpty { return title }
        return channelName
    }

    /// "6 min", "1 h 4 min".
    var durationShort: String {
        guard let duration else { return "–" }
        return Self.minutesText(duration)
    }

    static func minutesText(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "12:48", or "1:02:05" past an hour.
    var durationText: String {
        guard let duration else { return "–" }
        return RecorderModel.clock(duration.rounded())
    }
}
