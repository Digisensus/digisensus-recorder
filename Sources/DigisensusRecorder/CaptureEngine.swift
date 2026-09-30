import AVFoundation
import ScreenCaptureKit

enum AudioSource: Hashable {
    case application(bundleID: String)
    case systemAudio
    /// iPhone/FaceTime calls. Their audio is played by the avconferenced daemon, which
    /// ScreenCaptureKit doesn't capture at all, so the left channel comes from a process tap.
    case calls
}

enum CaptureError: LocalizedError {
    case noDisplay
    case appNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to attach the capture to."
        case .appNotRunning(let id): return "\(id) is not running."
        }
    }
}

/// Captures one app's audio plus the microphone through a single SCStream, so
/// both arrive with timestamps from the same clock.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Peak levels (0...1 linear) for left/app and right/mic as they are written to the file,
    /// i.e. after crosstalk removal and levelling. Called on the main queue.
    var onLevels: ((Float, Float) -> Void)?
    /// Called on the main queue when the stream dies or the file can't be written.
    var onFailure: ((Error) -> Void)?

    /// Processes that render call audio. DSREC_TAP_PROCESSES overrides the list for testing.
    private static var callProcessNames: [String] {
        if let override = ProcessInfo.processInfo.environment["DSREC_TAP_PROCESSES"] {
            return override.split(separator: ",").map(String.init)
        }
        return ["avconferenced", "callservicesd", "FaceTime", "Phone"]
    }

    private let queue = DispatchQueue(label: "com.digisensus.recorder.audio")
    private var stream: SCStream?
    private var writer: StereoWriter?
    private var tap: ProcessTap?
    private var usesTap = false
    private let appConverter = MonoConverter(downmix: .average)
    private let micConverter = MonoConverter(downmix: .first)
    private var appPeak: Float = 0
    private var micPeak: Float = 0
    private var lastLevelReport = DispatchTime.now()

    /// Records into the lossless capture at `url` (see RecordingFile).
    func start(source: AudioSource, microphoneID: String?, url: URL,
               autoBalance: Bool, removeCrosstalk: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter: SCContentFilter
        switch source {
        case .application(let bundleID):
            let apps = content.applications.filter { $0.bundleIdentifier == bundleID }
            guard !apps.isEmpty else { throw CaptureError.appNotRunning(bundleID) }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        case .systemAudio:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .calls:
            // The stream only supplies the microphone here; its app audio is ignored.
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(StereoWriter.sampleRate)
        config.channelCount = 2
        config.captureMicrophone = true
        if let microphoneID { config.microphoneCaptureDeviceID = microphoneID }
        // Video is mandatory for an SCStream; keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let processor = autoBalance || removeCrosstalk
            ? StereoProcessor(levelling: autoBalance, gate: removeCrosstalk) : nil
        let writer = try StereoWriter(url: url, processor: processor)
        writer.onLevels = { [weak self] app, mic in self?.reportLevels(app: app, mic: mic) }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)

        queue.sync {
            self.writer = writer
            self.usesTap = source == .calls
        }
        do {
            try await stream.startCapture()
            if source == .calls {
                let tap = ProcessTap()
                try tap.start(processNames: Self.callProcessNames, queue: queue) { [weak self] mono, time in
                    self?.write(mono, pts: time, isApp: true)
                }
                self.tap = tap
            }
        } catch {
            try? await stream.stopCapture()
            queue.sync { self.writer = nil }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.stream = stream
    }

    struct SpeechStats {
        /// Seconds the other side and the microphone each carried speech.
        let them: Double
        let me: Double
    }

    /// Returns how much each side spoke, when crosstalk removal or levelling was on.
    @discardableResult
    func stop() async -> SpeechStats? {
        tap?.stop()
        tap = nil
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        var stats: SpeechStats?
        queue.sync {
            if let seconds = writer?.speechSeconds { stats = SpeechStats(them: seconds.left, me: seconds.right) }
            try? writer?.finish()
            writer = nil
        }
        return stats
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type != .screen, sampleBuffer.isValid else { return }
        let isApp = type == .audio
        if isApp && usesTap { return }
        guard let mono = (isApp ? appConverter : micConverter).convert(sampleBuffer) else { return }
        write(mono, pts: sampleBuffer.presentationTimeStamp, isApp: isApp)
    }

    private func write(_ mono: [Float], pts: CMTime, isApp: Bool) {
        guard let writer else { return }
        do {
            try writer.append(mono, pts: pts, to: isApp ? .left : .right)
        } catch {
            self.writer = nil
            DispatchQueue.main.async { self.onFailure?(error) }
        }
    }

    /// Called by the writer on the audio queue with the peaks of what it just wrote.
    private func reportLevels(app: Float, mic: Float) {
        appPeak = max(appPeak, app)
        micPeak = max(micPeak, mic)
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastLevelReport.uptimeNanoseconds > 60_000_000 else { return }
        lastLevelReport = now
        let levels = (appPeak, micPeak)
        appPeak = 0
        micPeak = 0
        DispatchQueue.main.async { self.onLevels?(levels.0, levels.1) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onFailure?(error) }
    }
}
