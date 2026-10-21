import AVFoundation

enum SystemAudioAccess {
    enum Status: String {
        case granted, denied, unavailable
    }

    static let didChange = Notification.Name("SystemAudioAccessDidChange")
    private static let lastStatusKey = "systemAudioStatus"
    private static let requestedKey = "askedSystemAudio"
    private static let probeTimeout: TimeInterval = 1.5
    private static let probeTimeoutAfterPrompt: TimeInterval = 5
    private static let silenceMeaningDenied = 24_000

    @MainActor static var lastKnown: Status? {
        UserDefaults.standard.string(forKey: lastStatusKey).flatMap(Status.init(rawValue:))
    }

    @MainActor static var wasRequested: Bool { UserDefaults.standard.bool(forKey: requestedKey) }

    @MainActor private static var running: Task<Status, Never>?

    @MainActor static func check() async -> Status {
        if let running { return await running.value }
        UserDefaults.standard.set(true, forKey: requestedKey)
        let task = Task { await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: probe()) }
        } }
        running = task
        let status = await task.value
        running = nil
        Log.write("system audio access: \(status.rawValue)")
        if status != .unavailable, status != lastKnown {
            UserDefaults.standard.set(status.rawValue, forKey: lastStatusKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        return status
    }

    private static func probe() -> Status {
        guard let tones = TonePlayer() else { return .unavailable }
        do { try tones.start() } catch {
            Log.write("system audio probe: no output (\(error))")
            return .unavailable
        }
        defer { tones.stop() }

        let own = ProcessInfo.processInfo.processIdentifier
        let tap = ProcessTap(target: .processes { $0.pid == own }, muted: true)
        guard tap.processCount > 0 else { return .unavailable }
        let listened = Listened()
        let started = Date()
        do {
            try tap.start(queue: DispatchQueue(label: "com.digisensus.recorder.access-probe")) { mono, _ in
                listened.add(mono)
            }
        } catch {
            Log.write("system audio probe: \(error)")
            return .unavailable
        }
        defer { tap.stop() }
        let prompted = Date().timeIntervalSince(started) > 0.5

        tones.play(TonePlayer.tone(frequency: 1_000, amplitude: 0.01, seconds: 0.25), looping: true)
        let deadline = Date().addingTimeInterval(prompted ? probeTimeoutAfterPrompt : probeTimeout)
        while !listened.heard, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if listened.heard { return .granted }
        guard listened.silentFrames >= silenceMeaningDenied else {
            Log.write("system audio probe: no audio arrived in time")
            return .unavailable
        }
        return .denied
    }

    private final class Listened: @unchecked Sendable {
        private let lock = NSLock()
        private var anySound = false
        private var silence = 0

        var heard: Bool { lock.withLock { anySound } }
        var silentFrames: Int { lock.withLock { silence } }

        func add(_ samples: [Float]) {
            let sound = samples.contains { $0 != 0 }
            lock.withLock {
                if sound { anySound = true } else { silence += samples.count }
            }
        }
    }
}
