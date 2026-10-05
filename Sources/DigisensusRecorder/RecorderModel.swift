import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

struct AppChoice: Identifiable, Hashable {
    let name: String
    let source: AudioSource
    var id: AudioSource { source }
}

struct MicChoice: Identifiable, Hashable {
    let name: String
    let deviceID: String?
    var id: String { deviceID ?? "" }
}

@MainActor
final class RecorderModel: ObservableObject {
    static let chromeBundleID = "com.google.Chrome"

    @Published var apps: [AppChoice] = []
    @Published var mics: [MicChoice] = []
    @Published var source: AudioSource = .application(bundleID: RecorderModel.chromeBundleID) {
        didSet { saveSelections() }
    }
    @Published var micID: String = "" {
        didSet { saveSelections() }
    }
    @Published var autoBalance = true {
        didSet { saveSelections() }
    }
    @Published var removeCrosstalk = true {
        didSet { saveSelections() }
    }

    var cleanUpAudio: Bool {
        get { autoBalance && removeCrosstalk }
        set {
            autoBalance = newValue
            removeCrosstalk = newValue
        }
    }
    @Published var autoRecord = false {
        didSet {
            guard autoRecord != oldValue else { return }
            UserDefaults.standard.set(autoRecord, forKey: "autoRecord")
            if autoRecord {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
            }
            pollCalls()
        }
    }
    @Published private(set) var autoStatus: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue, launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("launch at login failed: \(error)")
                message = "Couldn't change the login item: \(error.localizedDescription)"
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var appLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var micHistory: [Float] = []
    @Published private(set) var appHistory: [Float] = []
    static let historyLength = 110
    @Published var liveNotes = ""
    @Published private(set) var currentCall: DetectedCall?
    @Published private(set) var autoStarted = false
    @Published private(set) var audioTest = AudioTest.idle

    enum AudioTest: Equatable {
        case idle, running
        case done(me: Bool, them: Bool)
        case failed(String)
    }
    @Published private(set) var lastFile: URL?
    @Published private(set) var lastSaved: URL?
    @Published private(set) var lastDiscarded: String?
    private static let minimumSpeech = (me: 1.0, them: 2.0)
    var recordingName: String? { (pendingEncode?.final ?? lastFile)?.lastPathComponent }
    @Published var message: String?

    private let engine = CaptureEngine()
    private(set) lazy var library = LibraryStore(folder: folder)
    private var startedAt: Date?
    private var callTimer: Timer?
    private var callStreak = 0
    private(set) var lastCallSeen: Date?
    private var testPeaks: (me: Float, them: Float)?
    private var autoSuppressed = false
    private static let callEndGrace: TimeInterval = 5
    private static let callEndPadding: TimeInterval = 1
    private var pendingEncode: PendingEncode?

    private struct PendingEncode {
        let capture: URL
        let final: URL
        var keep: Double?
    }
    private var timer: Timer?

    let folder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Digisensus Recorder", isDirectory: true)

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "source") {
            switch saved {
            case "system": source = .systemAudio
            case "calls": source = .calls
            default: source = .application(bundleID: saved)
            }
        }
        micID = defaults.string(forKey: "mic") ?? ""
        autoBalance = defaults.object(forKey: "autoBalance") as? Bool ?? true
        removeCrosstalk = defaults.object(forKey: "removeCrosstalk") as? Bool ?? true
        autoRecord = defaults.bool(forKey: "autoRecord")

        engine.onLevels = { [weak self] app, mic in
            MainActor.assumeIsolated { self?.levels(app: app, mic: mic) }
        }
        engine.onFailure = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.message = "Recording stopped: \(error.localizedDescription)"
                Task { await self.stop() }
            }
        }
        refreshDevices()
        _ = library
        recoverCaptures()

        callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCalls() }
        }
    }

    private func levels(app: Float, mic: Float) {
        appLevel = app
        micLevel = mic
        appHistory = Array((appHistory + [app]).suffix(Self.historyLength))
        micHistory = Array((micHistory + [mic]).suffix(Self.historyLength))
        if let peaks = testPeaks { testPeaks = (max(peaks.me, mic), max(peaks.them, app)) }
    }

    func runAudioTest() async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        audioTest = .running
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            audioTest = .done(me: false, them: false)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digisensus-test-\(UUID().uuidString)\(RecordingFile.captureSuffix)")
        defer { try? FileManager.default.removeItem(at: url) }
        micHistory = []
        appHistory = []
        testPeaks = (0, 0)
        defer { testPeaks = nil }
        do {
            try await engine.start(source: .systemAudio, microphoneID: micID.isEmpty ? nil : micID, url: url,
                                   autoBalance: false, removeCrosstalk: false)
        } catch {
            Log.write("audio test failed: \(error)")
            audioTest = CGPreflightScreenCaptureAccess()
                ? .failed(error.localizedDescription) : .done(me: false, them: false)
            return
        }
        try? await Task.sleep(for: .seconds(5))
        await engine.stop()
        appLevel = 0
        micLevel = 0
        let peaks = testPeaks ?? (0, 0)
        Log.write(String(format: "audio test: mic peak %.3f, app peak %.3f", peaks.me, peaks.them))
        audioTest = .done(me: peaks.me > 0.02, them: peaks.them > 0.005)
    }

    var micName: String {
        mics.first { $0.id == micID }?.name ?? "System default"
    }

    var sourceName: String {
        apps.first { $0.source == source }?.name ?? "All apps"
    }

    func refreshDevices() {
        var choices = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> AppChoice? in
                guard let id = app.bundleIdentifier else { return nil }
                return AppChoice(name: app.localizedName ?? id, source: .application(bundleID: id))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !choices.contains(where: { $0.source == .application(bundleID: Self.chromeBundleID) }) {
            choices.insert(AppChoice(name: "Google Chrome (not running)",
                                     source: .application(bundleID: Self.chromeBundleID)), at: 0)
        }
        if case .application(let id) = source, !choices.contains(where: { $0.source == source }) {
            choices.insert(AppChoice(name: "\(id) (not running)", source: source), at: 0)
        }
        choices.append(AppChoice(name: "Phone & FaceTime calls", source: .calls))
        choices.append(AppChoice(name: "All apps", source: .systemAudio))
        apps = choices

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        mics = [MicChoice(name: "System default", deviceID: nil)]
            + devices.map { MicChoice(name: $0.localizedName, deviceID: $0.uniqueID) }
        if !mics.contains(where: { $0.id == micID }) { micID = "" }
    }

    nonisolated static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func toggle() {
        if isRecording, autoStarted { autoSuppressed = true }
        Task { isRecording ? await stop() : await start() }
    }

    private func pollCalls() {
        guard autoRecord else {
            autoStatus = nil
            return
        }
        if let call = CallDetector.currentCall() {
            lastCallSeen = Date()
            callStreak += 1
            if !isRecording, !isBusy, !autoSuppressed, callStreak >= 3 {
                Task { await start(detected: call) }
            }
            if !isRecording { autoStatus = autoSuppressed ? "\(call.label) call – not recording" : "\(call.label) call detected…" }
        } else {
            callStreak = 0
            autoSuppressed = false
            if isRecording, autoStarted, !isBusy,
               Date().timeIntervalSince(lastCallSeen ?? .distantPast) > Self.callEndGrace {
                Task { await stop() }
            }
            if !isRecording { autoStatus = "Waiting for a call…" }
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func startForAgent(client: String, source: AudioSource?) async -> Bool {
        if let source { self.source = source }
        await start()
        if isRecording {
            notify("Recording started by an AI agent", "“\(client)” started this recording.")
        }
        return isRecording
    }

    func start(detected: DetectedCall? = nil) async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        if let detected {
            source = detected.source
        }
        saveSelections()

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            message = "Microphone access denied. Enable Digisensus Recorder in System Settings › Privacy & Security › Microphone."
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            Permissions.requestSystemAudio()
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Date().formatted(.verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits)",
                timeZone: .current, calendar: .current))
            let name = "rec-\(stamp)" + (detected.map { "-\($0.label)" } ?? "")
            let final = folder.appendingPathComponent("\(name).\(RecordingFile.fileExtension)")
            let url = RecordingFile.captureURL(for: final)
            try await engine.start(source: source, microphoneID: micID.isEmpty ? nil : micID,
                                   url: url, autoBalance: autoBalance,
                                   removeCrosstalk: removeCrosstalk)
            pendingEncode = PendingEncode(capture: url, final: final)
            Log.write("recording started: \(url.lastPathComponent), source \(source)")
            lastFile = url
            liveNotes = ""
            micHistory = []
            appHistory = []
            isRecording = true
            currentCall = detected
            autoStarted = detected != nil
            if let detected {
                autoStatus = "Auto-recording \(detected.label) call"
                notify("Recording \(detected.label) call", "Digisensus Recorder started recording automatically.")
            }
            startedAt = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let startedAt = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
        } catch {
            Log.write("start failed: \(error)")
            if detected != nil { autoSuppressed = true }
            if CGPreflightScreenCaptureAccess() {
                message = error.localizedDescription
            } else {
                message = "Allow Digisensus Recorder in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch it."
            }
        }
    }

    func stop() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let speech = await engine.stop()
        let began = startedAt ?? Date()
        var duration = Date().timeIntervalSince(began)
        if let speech {
            Log.write(String(format: "speech heard: me %.1f s, them %.1f s", speech.me, speech.them))
        }
        let unanswered = autoStarted && speech.map { $0.me < Self.minimumSpeech.me && $0.them < Self.minimumSpeech.them } ?? false
        if autoStarted, !autoSuppressed, let lastCallSeen, pendingEncode != nil {
            let keep = lastCallSeen.timeIntervalSince(began) + Self.callEndPadding
            if keep > 1, keep < duration {
                pendingEncode?.keep = keep
                duration = keep
            }
        }
        timer?.invalidate()
        timer = nil
        startedAt = nil
        isRecording = false
        appLevel = 0
        micLevel = 0
        let wasAuto = autoStarted
        autoStarted = false

        if unanswered {
            let label = currentCall?.label ?? "Call"
            Log.write("discarding unanswered \(label) call (\(lastFile?.lastPathComponent ?? "-"))")
            if let pending = pendingEncode { try? FileManager.default.removeItem(at: pending.capture) }
            if let lastFile { try? FileManager.default.removeItem(at: lastFile) }
            pendingEncode = nil
            lastFile = nil
            lastDiscarded = label
            return
        }

        let notes = liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending = pendingEncode { RecordingFile.keepNotes(notes, for: pending.final) }
        defer {
            if let lastFile {
                library.register(file: lastFile, startedAt: began, duration: duration, call: currentCall,
                                 notes: notes.isEmpty ? nil : notes)
                try? FileManager.default.removeItem(at: RecordingFile.notesURL(for: lastFile))
                lastSaved = lastFile
                if wasAuto { notify("Call recording saved", lastFile.lastPathComponent) }
            }
            liveNotes = ""
        }

        if let pending = pendingEncode {
            pendingEncode = nil
            message = "Compressing…"
            let encoded = await Task.detached { Self.finishEncode(pending) || Self.finishEncode(pending) }.value
            if encoded {
                lastFile = pending.final
                message = nil
            } else {
                lastFile = nil
                message = "Couldn't compress this recording. It's kept and will be saved when Digisensus Recorder next starts."
            }
        }
    }

    private func recoverCaptures() {
        let folder = folder
        let library = library
        Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var recovered: [URL] = []
            for capture in files where capture.lastPathComponent.hasSuffix(RecordingFile.captureSuffix) {
                let recording = RecordingFile.recordingURL(forCapture: capture)
                let partial = recording.appendingPathExtension("part")
                var saved = RecordingFile.encodeOpus(from: capture, to: partial)
                if saved {
                    let files = FileManager.default
                    saved = files.fileExists(atPath: recording.path)
                        ? (try? files.replaceItemAt(recording, withItemAt: partial)) != nil
                        : (try? files.moveItem(at: partial, to: recording)) != nil
                }
                try? FileManager.default.removeItem(at: partial)
                if saved {
                    try? FileManager.default.removeItem(at: capture)
                    recovered.append(recording)
                }
                Log.write("recovering \(capture.lastPathComponent): \(saved ? "ok" : "FAILED")")
            }
            let saved = recovered
            if !saved.isEmpty { await MainActor.run { library.reindex(saved) } }
        }
    }

    private nonisolated static func finishEncode(_ pending: PendingEncode) -> Bool {
        let encoded = RecordingFile.encodeOpus(from: pending.capture, to: pending.final, duration: pending.keep)
        Log.write("opus encode \(pending.final.lastPathComponent): \(encoded ? "ok" : "FAILED")"
            + (pending.keep.map { String(format: ", trimmed to %.1f s", $0) } ?? ""))
        if encoded { try? FileManager.default.removeItem(at: pending.capture) }
        return encoded
    }

    func stopBeforeQuit() {
        guard isRecording else { return }
        let done = DispatchSemaphore(value: 0)
        let engine = engine
        let pending = pendingEncode
        if let pending { RecordingFile.keepNotes(liveNotes, for: pending.final) }
        Task.detached {
            await engine.stop()
            if let pending { _ = Self.finishEncode(pending) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func saveSelections() {
        let defaults = UserDefaults.standard
        switch source {
        case .application(let id): defaults.set(id, forKey: "source")
        case .systemAudio: defaults.set("system", forKey: "source")
        case .calls: defaults.set("calls", forKey: "source")
        }
        defaults.set(micID, forKey: "mic")
        defaults.set(autoBalance, forKey: "autoBalance")
        defaults.set(removeCrosstalk, forKey: "removeCrosstalk")
    }
}
