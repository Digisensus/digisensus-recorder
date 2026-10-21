import AVFoundation
import CoreMedia

enum RecordingFile {
    static let fileExtension = "ogg"
    static let captureSuffix = ".capture.caf"
    private static let captureSuffixes = [captureSuffix, ".capture.flac"]

    static let opusBitrate = 24_000
    static let monoOpusBitrate = opusBitrate / 2

    static func captureURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("capture").appendingPathExtension("caf")
    }

    static func isCapture(_ url: URL) -> Bool {
        captureSuffixes.contains { url.lastPathComponent.hasSuffix($0) }
    }

    static func recordingURL(forCapture capture: URL) -> URL {
        let suffix = captureSuffixes.first { capture.lastPathComponent.hasSuffix($0) } ?? captureSuffix
        let name = capture.lastPathComponent.dropLast(suffix.count)
        return capture.deletingLastPathComponent().appendingPathComponent("\(name).\(fileExtension)")
    }

    static func partialURL(for recording: URL) -> URL {
        recording.appendingPathExtension("part")
    }

    static func notesURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("notes.txt")
    }

    static func keepNotes(_ notes: String, for recording: URL) {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }
        try? notes.write(to: notesURL(for: recording), atomically: true, encoding: .utf8)
    }

    static var captureSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: StereoWriter.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    static func encodeOpus(from source: URL, to destination: URL, duration: Double? = nil) -> Bool {
        let partial = partialURL(for: destination)
        var encoded = 0
        do {
            let file = try AVAudioFile(forReading: source)
            let channels = Int(file.processingFormat.channelCount)
            guard file.processingFormat.sampleRate == OggOpusEncoder.sampleRate, channels > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 14)
            else { return false }
            guard file.length > 0 else {
                Log.write("opus encode: \(source.lastPathComponent) has no audio")
                return false
            }
            let encoder = try OggOpusEncoder(url: partial, channels: channels, bitrate: opusBitrate)
            var remaining = duration.map { Int(($0 * OggOpusEncoder.sampleRate).rounded()) } ?? Int.max
            var interleaved: [Float] = []
            while remaining > 0, file.framePosition < file.length {
                try file.read(into: buffer)
                let frames = min(Int(buffer.frameLength), remaining)
                guard frames > 0, let data = buffer.floatChannelData else { break }
                interleaved.removeAll(keepingCapacity: true)
                interleaved.reserveCapacity(frames * channels)
                for frame in 0..<frames {
                    for channel in 0..<channels { interleaved.append(data[channel][frame]) }
                }
                try interleaved.withUnsafeBufferPointer { try encoder.append($0) }
                remaining -= frames
                encoded += frames
            }
            try encoder.finish()
            guard encoded > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: partial)
            } else {
                try files.moveItem(at: partial, to: destination)
            }
        } catch {
            Log.write("opus encode failed: \(error)")
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        return true
    }
}

final class StereoWriter {
    enum Channel { case left, right }

    static let sampleRate: Double = 48_000
    private static let tolerance = Int(sampleRate / 10)
    private static let maxLag = Int(sampleRate * 2)
    private static let flushChunk = Int(sampleRate / 5)

    private struct Track {
        var samples: [Float] = []
        var origin: CMTime?
        var started = false
    }

    var onLevels: ((Float, Float) -> Void)?
    var speechSeconds: (left: Double, right: Double)? { processor?.speechSeconds }

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let processor: StereoProcessor?
    private var left = Track()
    private var right = Track()
    private var origin: CMTime?
    private var written = 0

    init(url: URL, processor: StereoProcessor?) throws {
        self.processor = processor
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                               channels: 2, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: RecordingFile.captureSettings,
                               commonFormat: .pcmFormatInt16, interleaved: false)
    }

    func append(_ mono: [Float], pts: CMTime, to channel: Channel) throws {
        guard !mono.isEmpty else { return }
        let origin = self.origin ?? pts
        self.origin = origin

        var track = channel == .left ? left : right
        let end = written + track.samples.count
        var expected = index(of: pts, origin: track.origin ?? origin)

        var tolerance = Self.tolerance
        if !track.started {
            track.started = true
            if abs(expected - end) > Int(Self.sampleRate * 5) {
                let shift = CMTime(value: CMTimeValue(end), timescale: CMTimeScale(Self.sampleRate))
                track.origin = pts - shift
                expected = end
            }
            tolerance = 0
        }

        let delta = expected - end
        if delta > tolerance {
            track.samples.append(contentsOf: repeatElement(0, count: delta))
            track.samples.append(contentsOf: mono)
        } else if delta < -tolerance {
            track.samples.append(contentsOf: mono.dropFirst(-delta))
        } else {
            track.samples.append(contentsOf: mono)
        }

        if channel == .left { left = track } else { right = track }
        try flush(all: false)
    }

    func finish() throws {
        try flush(all: true)
        file.close()
    }

    private func index(of pts: CMTime, origin: CMTime) -> Int {
        Int(((pts - origin).seconds * Self.sampleRate).rounded())
    }

    private func flush(all: Bool) throws {
        let longest = max(left.samples.count, right.samples.count)
        let floor = all ? longest : longest - Self.maxLag
        if left.samples.count < floor {
            left.samples.append(contentsOf: repeatElement(0, count: floor - left.samples.count))
        }
        if right.samples.count < floor {
            right.samples.append(contentsOf: repeatElement(0, count: floor - right.samples.count))
        }

        var frames = min(left.samples.count, right.samples.count)
        let block = StereoProcessor.blockSize
        if all {
            let pad = (block - frames % block) % block
            left.samples.append(contentsOf: repeatElement(0, count: pad))
            right.samples.append(contentsOf: repeatElement(0, count: pad))
            frames += pad
        } else {
            frames -= frames % block
        }
        guard frames > 0, all || frames >= Self.flushChunk else { return }
        if let processor {
            left.samples.withUnsafeMutableBufferPointer { l in
                right.samples.withUnsafeMutableBufferPointer { r in
                    for start in stride(from: 0, to: frames, by: block) {
                        processor.process(left: UnsafeMutableBufferPointer(rebasing: l[start..<start + block]),
                                          right: UnsafeMutableBufferPointer(rebasing: r[start..<start + block]))
                    }
                }
            }
        }
        if let onLevels {
            var peakL: Float = 0
            var peakR: Float = 0
            for frame in 0..<frames {
                peakL = max(peakL, abs(left.samples[frame]))
                peakR = max(peakR, abs(right.samples[frame]))
            }
            onLevels(peakL, peakR)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let data = buffer.int16ChannelData {
            for (channel, track) in [left, right].enumerated() {
                for frame in 0..<frames {
                    data[channel][frame] = Int16(max(-1, min(1, track.samples[frame])) * 32_767)
                }
            }
        }
        try file.write(from: buffer)

        left.samples.removeFirst(frames)
        right.samples.removeFirst(frames)
        written += frames
    }
}
