import AppKit
import AVFoundation

enum AudioSource: Hashable {
    case application(bundleID: String)
    case systemAudio
    case calls
}

enum CaptureError: LocalizedError {
    case appNotRunning(String)
    case noMicrophone
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let id): return "\(id) is not running."
        case .noMicrophone: return "No microphone found."
        case .microphoneUnavailable: return "The microphone couldn't be opened."
        }
    }
}

final class CaptureEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onLevels: ((Float, Float) -> Void)?
    var onFailure: ((Error) -> Void)?

    private static var callProcessNames: [String] {
        if let override = ProcessInfo.processInfo.environment["DSREC_TAP_PROCESSES"] {
            return override.split(separator: ",").map(String.init)
        }
        return ["avconferenced", "callservicesd", "FaceTime", "Phone"]
    }

    private let queue = DispatchQueue(label: "com.digisensus.recorder.audio")
    private let control = DispatchQueue(label: "com.digisensus.recorder.capture-control")
    private var session: AVCaptureSession?
    private var micClock: CMClock?
    private var sessionObserver: NSObjectProtocol?
    private var writer: StereoWriter?
    private var tap: ProcessTap?
    private let micConverter = MonoConverter(downmix: .first)
    private var appPeak: Float = 0
    private var micPeak: Float = 0
    private var lastLevelReport = DispatchTime.now()

    func start(source: AudioSource, microphoneID: String?, url: URL,
               autoBalance: Bool, removeCrosstalk: Bool) async throws {
        let processor = autoBalance || removeCrosstalk
            ? StereoProcessor(levelling: autoBalance, gate: removeCrosstalk) : nil
        let target = try Self.tapTarget(for: source)
        try await onControl { try self.start(target: target, microphoneID: microphoneID, url: url, processor: processor) }
    }

    func startTest(microphoneID: String?, url: URL) async throws {
        let own = ProcessInfo.processInfo.processIdentifier
        try await onControl {
            try self.start(target: .processes { $0.pid == own }, microphoneID: microphoneID, url: url, processor: nil)
        }
    }

    private func onControl<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            control.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func start(target: ProcessTap.Target, microphoneID: String?, url: URL,
                       processor: StereoProcessor?) throws {
        let writer = try StereoWriter(url: url, processor: processor)
        writer.onLevels = { [weak self] app, mic in self?.reportLevels(app: app, mic: mic) }
        queue.sync { self.writer = writer }

        do {
            let session = try makeMicrophoneSession(deviceID: microphoneID)
            self.session = session
            queue.sync { self.micClock = session.synchronizationClock }
            session.startRunning()
            guard session.isRunning else { throw CaptureError.microphoneUnavailable }

            let tap = ProcessTap(target: target)
            tap.onFailure = { [weak self] error in DispatchQueue.main.async { self?.onFailure?(error) } }
            try tap.start(queue: queue) { [weak self] mono, time in
                self?.write(mono, pts: time, isApp: true)
            }
            self.tap = tap
        } catch {
            stopSources()
            queue.sync { self.writer = nil }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    struct SpeechStats {
        let them: Double
        let me: Double
    }

    @discardableResult
    func stop() async -> SpeechStats? {
        (try? await onControl { self.stopNow() }) ?? nil
    }

    private func stopNow() -> SpeechStats? {
        stopSources()
        var stats: SpeechStats?
        queue.sync {
            if let seconds = writer?.speechSeconds { stats = SpeechStats(them: seconds.left, me: seconds.right) }
            do { try writer?.finish() } catch { Log.write("capture file: \(error)") }
            writer = nil
        }
        return stats
    }

    private func stopSources() {
        tap?.stop()
        tap = nil
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
        sessionObserver = nil
        session?.stopRunning()
        session = nil
        queue.sync { micClock = nil }
    }

    private static func tapTarget(for source: AudioSource) throws -> ProcessTap.Target {
        let own = ProcessInfo.processInfo.processIdentifier
        switch source {
        case .application(let bundleID):
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard !apps.isEmpty else { throw CaptureError.appNotRunning(bundleID) }
            let pids = Set(apps.map(\.processIdentifier))
            return .processes { process in
                process.pid != own && (pids.contains(process.pid) || process.bundleID.hasPrefix(bundleID)
                    || process.webKitOwner.map { pids.contains($0.processIdentifier) } == true)
            }
        case .systemAudio:
            return .everythingExcept { $0.pid == own }
        case .calls:
            let names = callProcessNames
            return .processes { names.contains($0.name) }
        }
    }

    private func makeMicrophoneSession(deviceID: String?) throws -> AVCaptureSession {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw CaptureError.noMicrophone }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: StereoWriter.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.microphoneUnavailable }
        session.addInput(input)
        session.addOutput(output)
        sessionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? CaptureError.microphoneUnavailable
            self?.onFailure?(error)
        }
        Log.write("microphone: \(device.localizedName)")
        return session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let mono = micConverter.convert(sampleBuffer) else { return }
        write(mono, pts: hostTime(of: sampleBuffer.presentationTimeStamp), isApp: false)
    }

    private func hostTime(of pts: CMTime) -> CMTime {
        guard let clock = micClock else { return pts }
        return CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
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
}
