import AppKit
import AVFoundation
import GRDB

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published var searchText = "" {
        didSet { runSearch() }
    }
    @Published private(set) var searchHits: [TranscriptSearchHit] = []
    @Published var selection: Int64?
    @Published var pendingDeletion: Recording?

    enum ListMode { case day, all }
    @Published var listMode = ListMode.day
    @Published private(set) var calendarMonth = LibraryStore.startOfMonth(Date())
    @Published private(set) var selectedDay = Calendar.current.startOfDay(for: Date())
    @Published var sourceFilter: Set<String> = []
    @Published var tagFilter: Set<String> = []

    var isFiltering: Bool { !sourceFilter.isEmpty || !tagFilter.isEmpty }

    func passesFilters(_ recording: Recording) -> Bool {
        (sourceFilter.isEmpty || sourceFilter.contains(recording.sourceKey))
            && (tagFilter.isEmpty || recording.tags.contains(where: tagFilter.contains))
    }

    var filteredRecordings: [Recording] { recordings.filter(passesFilters) }

    var listedRecordings: [Recording] {
        let filtered = filteredRecordings
        guard listMode == .day else { return filtered }
        return filtered.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: selectedDay) }
    }

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

    @Published var transcription = LibraryStore.loadTranscriptionSettings() {
        didSet {
            let keyChanged = transcription.apiKey != oldValue.apiKey
            saveTranscriptionSettings(keyChanged: keyChanged)
            if keyChanged, summary.sharesService(with: transcription), summary.apiKey != transcription.apiKey {
                summary.apiKey = transcription.apiKey
            }
        }
    }
    @Published var autoTranscribe = UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    @Published private(set) var transcribing: Set<Int64> = []
    @Published private(set) var processing: [Int64: String] = [:]
    private var transcriptionJobs: [Int64: Task<Void, Never>] = [:]
    @Published private(set) var transcriptionErrors: [Int64: String] = [:]
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var agreementRevision = 0
    @Published private(set) var addingToCalendar: Set<Int64> = []
    @Published private(set) var agreementErrors: [Int64: String] = [:]
    private let calendarWriter = CalendarWriter()
    @Published private(set) var connectionStatus: String?

    @Published var summary = LibraryStore.loadSummarySettings() {
        didSet {
            let keyChanged = summary.apiKey != oldValue.apiKey
            saveSummarySettings(keyChanged: keyChanged)
            if keyChanged, transcription.sharesService(with: summary), transcription.apiKey != summary.apiKey {
                transcription.apiKey = summary.apiKey
            }
        }
    }
    @Published var autoSummarize = UserDefaults.standard.object(forKey: "autoSummarize") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSummarize, forKey: "autoSummarize") }
    }
    @Published private(set) var summarizing: Set<Int64> = []
    @Published private(set) var summaryErrors: [Int64: String] = [:]
    @Published private(set) var summaryConnectionStatus: String?

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
        resumeTranscriptions()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self?.resumeTranscriptions()
            }
        }
    }

    static let interrupted = "Transcription was interrupted. Try again."
    static let tookTooLong = "Transcription did not finish within 2 hours. Try again."

    func resumeTranscriptions() {
        guard let pending = try? database.pendingTranscriptions() else { return }
        for recording in pending {
            guard let id = recording.id else { continue }
            if let jobID = recording.transcriptJobID, let settings = transcriptionSettings(), settings.provider == .digisensus {
                transcriptionJobs[id]?.cancel()
                transcribing.insert(id)
                let client = TranscriptionClient(settings: settings)
                transcriptionJobs[id] = Task {
                    await self.pollJob(jobID, recording: recording, client: client, polls: recording.transcriptJobPolls,
                                       summarizeAfter: nil)
                }
            } else if transcriptionJobs[id] == nil {
                try? database.setTranscriptStatus(.failed, recordingID: id)
                transcriptionErrors[id] = Self.interrupted
            }
        }
    }

    func url(for recording: Recording) -> URL {
        folder.appendingPathComponent(recording.fileName)
    }

    func registerProcessing(file: URL, startedAt: Date, duration: Double, call: DetectedCall?,
                            notes: String? = nil) -> Int64? {
        var bundleID: String?
        if case .application(let id) = call?.source { bundleID = id }
        let recording = Recording(
            fileName: file.lastPathComponent, startedAt: startedAt, duration: duration,
            sourceLabel: call?.label, sourceBundleID: bundleID, autoStarted: call != nil,
            format: RecordingFile.fileExtension, sizeBytes: 0, notes: notes,
            transcriptStatus: .none, fileMissing: false)
        do {
            guard let id = try database.saveRecording(recording).id else { return nil }
            processing[id] = file.lastPathComponent
            return id
        } catch {
            Log.write("could not index \(file.lastPathComponent): \(error)")
            return nil
        }
    }

    func finishProcessing(_ id: Int64, file: URL, duration: Double) {
        processing[id] = nil
        guard (try? database.recording(id: id)) != nil else {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
            return
        }
        do {
            try database.setFile(sizeBytes: Self.size(of: file), duration: duration, recordingID: id)
            if autoTranscribe, aiService != .off, transcriptionSettings() != nil,
               let saved = try database.recording(id: id) {
                transcribe(saved)
            }
        } catch {
            Log.write("could not index \(file.lastPathComponent): \(error)")
        }
    }

    func abandonProcessing(_ id: Int64) {
        processing[id] = nil
        try? database.deleteRecording(id: id)
    }

    func transcribe(_ recording: Recording, summarizeAfter: Bool? = nil) {
        guard let id = recording.id, !transcribing.contains(id), processing[id] == nil else { return }
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
        if settings.provider == .digisensus {
            transcriptionJobs[id] = Task {
                do {
                    let job = try await client.submit(file)
                    try database.setTranscriptJob(id: job.id, startedAt: Date(), recordingID: id)
                    await pollJob(job.id, recording: recording, client: client, polls: 0, summarizeAfter: summarizeAfter)
                } catch is CancellationError {
                    return
                } catch {
                    finishTranscription(id, recording: recording, settings: settings, error: error)
                }
            }
            return
        }
        transcriptionJobs[id] = Task {
            do {
                let started = Date()
                let result = try await client.transcribe(file)
                try saveTranscription(result, recording: recording, model: settings.model, started: started,
                                      summarizeAfter: summarizeAfter)
                finishTranscription(id, recording: recording, settings: settings, error: nil)
            } catch is CancellationError {
                return
            } catch {
                finishTranscription(id, recording: recording, settings: settings, error: error)
            }
        }
    }

    private func pollJob(_ jobID: String, recording: Recording, client: TranscriptionClient, polls startPolls: Int,
                         summarizeAfter: Bool?) async {
        guard let id = recording.id else { return }
        let started = recording.transcriptJobStartedAt ?? Date()
        var polls = startPolls
        var hint: Double?
        while let delay = TranscriptionClient.pollDelay(after: polls) {
            do {
                try await Task.sleep(for: .seconds(max(delay, hint ?? 0)))
            } catch {
                return
            }
            polls += 1
            try? database.setTranscriptJobPolls(polls, recordingID: id)
            do {
                switch try await client.poll(jobID) {
                case .running(let waitHint):
                    hint = waitHint
                case .done(let response):
                    do {
                        let result = try await client.finish(response, file: url(for: recording)) {
                            try await client.submitAndWait($0)
                        }
                        try saveTranscription(result, recording: recording, model: client.settings.model, started: started,
                                              summarizeAfter: summarizeAfter)
                        finishTranscription(id, recording: recording, settings: client.settings, error: nil)
                    } catch is CancellationError {
                    } catch {
                        finishTranscription(id, recording: recording, settings: client.settings, error: error)
                    }
                    return
                case .failed(let message):
                    finishTranscription(id, recording: recording, settings: client.settings,
                                        error: TranscriptionError.server(200, message))
                    return
                }
            } catch is CancellationError {
                return
            } catch let error as TranscriptionError {
                finishTranscription(id, recording: recording, settings: client.settings, error: error)
                return
            } catch {
                Log.write("poll of job \(jobID) failed (\(polls)): \(Log.describe(error))")
            }
        }
        await client.cancel(jobID)
        finishTranscription(id, recording: recording, settings: client.settings, error: TranscriptionError.server(504, Self.tookTooLong))
    }

    private func saveTranscription(_ result: TranscriptionResult, recording: Recording, model: String, started: Date,
                                   summarizeAfter: Bool?) throws {
        guard let id = recording.id else { return }
        let segments = result.turns.map {
            TranscriptSegment(recordingId: id, channel: $0.channel, startTime: $0.start, endTime: $0.end, text: $0.text)
        }
        try database.saveTranscript(recordingID: id, segments: segments, language: result.language, model: model)
        Log.write(String(format: "transcribed %@: %d turns in %.1f s", recording.fileName,
                         segments.count, Date().timeIntervalSince(started)))
        if summarizeAfter ?? autoSummarize, aiService != .off, !segments.isEmpty, summarySettings() != nil {
            summarize(recording)
        }
    }

    private func finishTranscription(_ id: Int64, recording: Recording, settings: TranscriptionSettings, error: Error?) {
        if let error {
            try? database.setTranscriptStatus(.failed, recordingID: id)
            let message: String
            if case TranscriptionError.server(200, let detail) = error { message = detail } else { message = error.localizedDescription }
            transcriptionErrors[id] = message
            Log.write("transcription of \(recording.fileName) failed: \(Log.describe(error))")
        } else {
            transcriptionErrors[id] = nil
        }
        transcribing.remove(id)
        transcriptionJobs[id] = nil
        transcriptRevision += 1
        if settings.provider == .digisensus { Task { await account.refresh() } }
    }

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

        let knownTags = allTags
        Task {
            let settings = await withSummaryModel(settings)
            let client = SummaryClient(settings: settings)
            let model = settings.model
            do {
                let started = Date()
                let result = try await client.summarize(segments, knownTags: knownTags, recordedAt: recording.startedAt)
                try database.saveSummary(result, model: model, recordingID: id)
                agreementRevision += 1
                Log.write(String(format: "summarised %@ in %.1f s", recording.fileName, Date().timeIntervalSince(started)))
            } catch {
                summaryErrors[id] = error.localizedDescription
                Log.write("summary of \(recording.fileName) failed: \(Log.describe(error))")
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
        Task {
            let checked = await withSummaryModel(settings)
            let status = await SummaryClient(settings: checked).checkConnection()
            if summarySettings().map({ Self.sameService($0, settings) }) == true { summaryConnectionStatus = status }
        }
    }

    private static func sameService(_ a: some AIServiceSettings, _ b: some AIServiceSettings) -> Bool {
        a.provider == b.provider && a.preset == b.preset && a.server == b.server && a.apiKey == b.apiKey
    }

    private func withSummaryModel(_ settings: SummarySettings) async -> SummarySettings {
        guard settings.provider != .digisensus, settings.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            return settings
        }
        let listed = await ModelList.fetch(settings, for: .summary)
        guard let model = ModelList.likelyChatModel(in: listed.names) else { return settings }
        Log.write("summary model not set, using \(model)")
        var chosen = settings
        chosen.model = model
        if Self.sameService(summary, settings), summary.model.isEmpty { summary.model = model }
        return chosen
    }

    func choose(_ preset: AIPreset, for purpose: AIPurpose) {
        switch purpose {
        case .transcription:
            guard transcription.preset != preset.id else { return }
            var settings = transcription
            settings.use(preset, for: .transcription, keyFrom: summary)
            if settings.apiKey.isEmpty { settings.apiKey = Self.storedKey("transcription", preset: preset.id) }
            transcription = settings
            connectionStatus = nil
        case .summary:
            guard summary.preset != preset.id else { return }
            var settings = summary
            settings.use(preset, for: .summary, keyFrom: transcription)
            if settings.apiKey.isEmpty { settings.apiKey = Self.storedKey("summary", preset: preset.id) }
            summary = settings
            summaryConnectionStatus = nil
        }
    }

    func checkConnection() {
        guard let settings = transcriptionSettings() else {
            connectionStatus = Self.signInNeeded
            return
        }
        connectionStatus = "Checking…"
        let client = TranscriptionClient(settings: settings)
        Task {
            let status = await client.checkConnection()
            if transcriptionSettings().map({ Self.sameService($0, settings) }) == true { connectionStatus = status }
        }
    }

    private static let signInNeeded = "Sign in to Digisensus in Settings › Transcription & AI, or choose Local & Cloud API."
    private static let aiIsOff = "Transcription is off. Choose a service in Settings › Transcription & AI."

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

    private static func keyAccount(_ purpose: String, preset: String) -> String {
        "\(purpose)-api-key.\(preset)"
    }

    private static func storedKey(_ purpose: String, preset: String) -> String {
        let account = keyAccount(purpose, preset: preset)
        if let key = Keychain.string(account) { return key }
        guard let legacy = Keychain.string("\(purpose)-api-key") else { return "" }
        Keychain.set(legacy, for: account)
        Keychain.set(nil, for: "\(purpose)-api-key")
        return legacy
    }

    private static func migrateServerAddresses() {
        let defaults = UserDefaults.standard
        let migrated = "serverAddressesAreAPIRoots"
        guard !defaults.bool(forKey: migrated) else { return }
        for key in ["transcriptionServer", "summaryServer"] {
            if let address = defaults.string(forKey: key) {
                defaults.set(URL.apiRoot(fromLegacyAddress: address), forKey: key)
            }
        }
        defaults.set(true, forKey: migrated)
    }

    private static func loadSummarySettings() -> SummarySettings {
        migrateServerAddresses()
        let defaults = UserDefaults.standard
        var settings = SummarySettings()
        settings.provider = provider(forKey: "summaryProvider")
        settings.server = defaults.string(forKey: "summaryServer") ?? settings.server
        settings.preset = defaults.string(forKey: "summaryPreset")
            ?? AIPreset.matching(server: settings.server, for: .summary).id
        if let fixed = AIPreset.named(settings.preset)?.server { settings.server = fixed }
        settings.apiKey = storedKey("summary", preset: settings.preset)
        settings.model = defaults.string(forKey: "summaryModel") ?? settings.model
        return settings
    }

    private func saveSummarySettings(keyChanged: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(summary.provider.rawValue, forKey: "summaryProvider")
        defaults.set(summary.preset, forKey: "summaryPreset")
        defaults.set(summary.server, forKey: "summaryServer")
        defaults.set(summary.model, forKey: "summaryModel")
        if keyChanged { Keychain.set(summary.apiKey, for: Self.keyAccount("summary", preset: summary.preset)) }
    }

    private static func loadTranscriptionSettings() -> TranscriptionSettings {
        migrateServerAddresses()
        let defaults = UserDefaults.standard
        var settings = TranscriptionSettings()
        settings.provider = provider(forKey: "transcriptionProvider")
        settings.server = defaults.string(forKey: "transcriptionServer") ?? settings.server
        settings.preset = defaults.string(forKey: "transcriptionPreset")
            ?? AIPreset.matching(server: settings.server, for: .transcription).id
        if let fixed = AIPreset.named(settings.preset)?.server { settings.server = fixed }
        settings.apiKey = storedKey("transcription", preset: settings.preset)
        settings.model = defaults.string(forKey: "transcriptionModel") ?? settings.model
        settings.language = defaults.string(forKey: "transcriptionLanguage") ?? ""
        return settings
    }

    private func saveTranscriptionSettings(keyChanged: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(transcription.provider.rawValue, forKey: "transcriptionProvider")
        defaults.set(transcription.preset, forKey: "transcriptionPreset")
        defaults.set(transcription.server, forKey: "transcriptionServer")
        defaults.set(transcription.model, forKey: "transcriptionModel")
        defaults.set(transcription.language, forKey: "transcriptionLanguage")
        if keyChanged { Keychain.set(transcription.apiKey, for: Self.keyAccount("transcription", preset: transcription.preset)) }
    }

    func syncFolder() {
        let folder = folder
        let database = database
        let processingFiles = Set(processing.values)
        Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]) else { return }
            let audio = files.filter { $0.pathExtension.lowercased() == RecordingFile.fileExtension }
            do {
                let known = try database.knownFileNames()
                for file in audio where !known.contains(file.lastPathComponent) {
                    try database.saveRecording(Self.describe(file))
                    try? FileManager.default.removeItem(at: RecordingFile.notesURL(for: file))
                }
                try database.markMissing(except: Set(audio.map(\.lastPathComponent)).union(processingFiles))
            } catch {
                Log.write("folder sync failed: \(error)")
            }
        }
    }

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

    func recording(id: Int64) -> Recording? {
        try? database.recording(id: id)
    }

    func recording(fileName: String) -> Recording? {
        try? database.recording(fileName: fileName)
    }

    func segments(of recording: Recording) -> [TranscriptSegment] {
        guard let id = recording.id else { return [] }
        return (try? database.segments(recordingID: id)) ?? []
    }

    func agreements(of recording: Recording) -> [Agreement] {
        guard let id = recording.id else { return [] }
        return ((try? database.agreements(recordingID: id)) ?? []).filter { $0.status != .dismissed }
    }

    func addToCalendar(_ agreement: Agreement, from recording: Recording, destination: CalendarDestination) {
        guard let id = agreement.id, !addingToCalendar.contains(id) else { return }
        addingToCalendar.insert(id)
        agreementErrors[id] = nil
        Task {
            do {
                try await calendarWriter.add(agreement, from: recording, to: destination)
                var added = agreement
                added.status = .added
                try database.saveAgreement(added)
                Log.write("added an agreement of \(recording.fileName) to \(destination.rawValue)")
            } catch {
                agreementErrors[id] = error.localizedDescription
                Log.write("could not add an agreement of \(recording.fileName) to \(destination.rawValue): \(Log.describe(error))")
            }
            addingToCalendar.remove(id)
            agreementRevision += 1
        }
    }

    func dismiss(_ agreement: Agreement) {
        var dismissed = agreement
        dismissed.status = .dismissed
        do {
            try database.saveAgreement(dismissed)
        } catch {
            Log.write("could not dismiss an agreement: \(error)")
        }
        agreementRevision += 1
    }

    func searchTranscripts(_ query: String, limit: Int) -> [TranscriptSearchHit] {
        (try? database.searchTranscripts(query, limit: limit)) ?? []
    }

    func play(_ recording: Recording) {
        NSWorkspace.shared.open(url(for: recording))
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: recording)])
    }

    func save(_ recording: Recording) {
        guard let id = recording.id else { return }
        do {
            try database.setTitleAndNotes(title: recording.title, notes: recording.notes, recordingID: id)
        } catch {
            Log.write("could not save \(recording.fileName): \(error)")
        }
    }

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

    func trash(_ recording: Recording) {
        guard let id = recording.id else { return }
        transcriptionJobs[id]?.cancel()
        transcriptionJobs[id] = nil
        transcribing.remove(id)
        if let jobID = recording.transcriptJobID, let settings = transcriptionSettings(), settings.provider == .digisensus {
            let client = TranscriptionClient(settings: settings)
            Task { await client.cancel(jobID) }
        }
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
        let snippet: String?
        var id: Int64 { recording.rowID }
    }

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

enum AIService: String, CaseIterable, Identifiable {
    case digisensus, own, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .digisensus: return "Digisensus FREE"
        case .own: return "Local & Cloud API"
        case .off: return "Off"
        }
    }
}

extension Recording {
    var rowID: Int64 { id ?? -1 }

    var channelName: String { Self.channelName(for: sourceLabel) }

    static func channelName(for sourceLabel: String?) -> String {
        switch sourceLabel {
        case nil: return "Recording"
        case "Phone": return "Phone call"
        case "Meet": return "Google Meet call"
        case let label?: return "\(label) call"
        }
    }

    var sourceKey: String { sourceLabel ?? "Manual" }

    var isPhoneCall: Bool { sourceLabel == "Phone" }

    var heading: String {
        if let title, !title.isEmpty { return title }
        if let summaryTopic, !summaryTopic.isEmpty { return summaryTopic }
        return channelName
    }

    var titleOrChannel: String {
        if let title, !title.isEmpty { return title }
        return channelName
    }

    var durationShort: String {
        guard let duration else { return "–" }
        return Self.minutesText(duration)
    }

    static func minutesText(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    var durationText: String {
        guard let duration else { return "–" }
        return RecorderModel.clock(duration.rounded())
    }
}

extension String {
    var safeFileName: String {
        String(components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-").prefix(80))
    }
}
