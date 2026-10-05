import AVFoundation
import SwiftUI

@MainActor
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum ChannelMode: String, CaseIterable, Identifiable {
        case both = "Both", them = "Them", me = "Me"
        var id: String { rawValue }
        var pan: Float { self == .both ? 0 : self == .them ? -1 : 1 }
    }

    static let rates: [Float] = [1, 1.25, 1.5, 2]
    nonisolated static let waveformBins = 600

    @Published private(set) var isPreparing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var failure: String?
    @Published private(set) var peaks: [[Float]] = [[], []]
    @Published var currentTime: TimeInterval = 0
    @Published var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    @Published var channelMode: ChannelMode = .both {
        didSet { player?.pan = channelMode.pan }
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var decodedCopy: URL?
    private var loadTask: Task<Void, Never>?

    private nonisolated static let cacheFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("DigisensusRecorderPlayback", isDirectory: true)

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }

    func load(_ url: URL) {
        unload()
        guard FileManager.default.fileExists(atPath: url.path) else {
            failure = "The audio file is missing."
            return
        }
        isPreparing = true
        loadTask = Task { [weak self] in
            let playable = await Task.detached(priority: .userInitiated) { Self.playableCopy(of: url) }.value
            guard let self, !Task.isCancelled else {
                if let playable, playable != url { try? FileManager.default.removeItem(at: playable) }
                return
            }
            guard let playable, let player = try? AVAudioPlayer(contentsOf: playable) else {
                self.isPreparing = false
                self.failure = "This file can't be played."
                return
            }
            self.decodedCopy = playable == url ? nil : playable
            player.delegate = self
            player.enableRate = true
            player.rate = self.rate
            player.pan = self.channelMode.pan
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            self.isPreparing = false

            let peaks = await Task.detached(priority: .utility) { Self.waveform(of: playable) }.value
            if !Task.isCancelled { self.peaks = peaks }
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        stopTimer()
        player?.stop()
        player = nil
        if let decodedCopy { try? FileManager.default.removeItem(at: decodedCopy) }
        decodedCopy = nil
        isPlaying = false
        isPreparing = false
        failure = nil
        duration = 0
        currentTime = 0
        peaks = [[], []]
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            stopTimer()
        } else {
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            startTimer()
        }
        isPlaying = player.isPlaying
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, player.duration - 0.01))
        currentTime = player.currentTime
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            stopTimer()
            isPlaying = false
            currentTime = duration
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private nonisolated static func playableCopy(of url: URL) -> URL? {
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let copy = cacheFolder.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            var writer: PCMFileWriter?
            try OggOpusDecoder.decode(url) { samples, frames in
                if writer == nil {
                    let channels = samples.count / frames
                    writer = try PCMFileWriter(url: copy, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000.0,
                        AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    ], channels: channels)
                }
                try writer?.write(samples, frames: frames)
            }
            guard let writer else { return nil }
            writer.finish()
        } catch {
            Log.write("could not decode \(url.lastPathComponent) for playback: \(error)")
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
        return copy
    }

    private nonisolated static func waveform(of url: URL) -> [[Float]] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16)
        else { return [[], []] }
        let channels = Int(file.processingFormat.channelCount)
        let framesPerBin = max(1, Double(file.length) / Double(waveformBins))
        var peaks = [[Float]](repeating: [Float](repeating: 0, count: waveformBins), count: 2)

        var position = 0
        while position < Int(file.length), (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
              let data = buffer.floatChannelData {
            if Task.isCancelled { return [[], []] }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(waveformBins - 1, Int(Double(position + frame) / framesPerBin))
                for lane in 0..<2 {
                    let sample = abs(data[min(lane, channels - 1)][frame])
                    if sample > peaks[lane][bin] { peaks[lane][bin] = sample }
                }
            }
            position += Int(buffer.frameLength)
        }
        return peaks
    }
}
