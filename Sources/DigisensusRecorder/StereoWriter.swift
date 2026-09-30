import AVFoundation
import CoreMedia

/// Every recording is Ogg Opus: the only format the Digisensus service accepts, and what it
/// bills from (the file's own length). While a call is recorded the audio goes to a lossless
/// FLAC capture beside it, so a crash mid-call still leaves something to encode; on stop the
/// capture is compressed to the .ogg and deleted.
enum RecordingFile {
    static let fileExtension = "ogg"
    static let captureSuffix = ".capture.flac"

    /// Total for both channels, so 12 kbps each. Each is coded as an independent stream (see
    /// OggOpusEncoder), so a silent side costs almost nothing and the talking side gets the
    /// whole budget. Wideband speech at this rate still transcribes as well as the original.
    static let opusBitrate = 24_000
    /// For one channel on its own, as sent for transcription.
    static let monoOpusBitrate = opusBitrate / 2

    /// "rec-…-Zoom.ogg" is captured as "rec-…-Zoom.capture.flac".
    static func captureURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("capture").appendingPathExtension("flac")
    }

    static func recordingURL(forCapture capture: URL) -> URL {
        let name = capture.lastPathComponent.dropLast(captureSuffix.count)
        return capture.deletingLastPathComponent().appendingPathComponent("\(name).\(fileExtension)")
    }

    /// Notes typed during a call wait here, beside the recording, until the library has them:
    /// they survive a failed compression or a quit mid-call, and indexing the file picks them up.
    /// "rec-…-Zoom.ogg" → "rec-…-Zoom.notes.txt".
    static func notesURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("notes.txt")
    }

    static func keepNotes(_ notes: String, for recording: URL) {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }
        try? notes.write(to: notesURL(for: recording), atomically: true, encoding: .utf8)
    }

    /// 16-bit stereo FLAC at 48 kHz.
    static var captureSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: StereoWriter.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
        ]
    }

    /// Compresses a finished capture to Ogg Opus, keeping only the first `duration` seconds
    /// when given. Blocks until done.
    static func encodeOpus(from source: URL, to destination: URL, duration: Double? = nil) -> Bool {
        do {
            let file = try AVAudioFile(forReading: source)
            let channels = Int(file.processingFormat.channelCount)
            guard file.processingFormat.sampleRate == OggOpusEncoder.sampleRate, channels > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 14)
            else { return false }
            let encoder = try OggOpusEncoder(url: destination, channels: channels, bitrate: opusBitrate)
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
            }
            try encoder.finish()
        } catch {
            Log.write("opus encode failed: \(error)")
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        return size > 0
    }
}

/// Places two independent mono streams on a shared timeline (by presentation
/// timestamp), runs the aligned pair through the processor and writes them as one
/// stereo file: left = app, right = mic.
/// Not thread-safe; call everything from a single serial queue.
final class StereoWriter {
    enum Channel { case left, right }

    static let sampleRate: Double = 48_000
    /// Timestamp jitter below this is ignored and buffers are appended back to back.
    private static let tolerance = Int(sampleRate / 10)
    /// A stream that falls this far behind the other is filled with silence.
    private static let maxLag = Int(sampleRate * 2)
    /// A whole number of processor blocks.
    private static let flushChunk = Int(sampleRate / 5)

    private struct Track {
        var samples: [Float] = []
        /// Set when this stream's clock turned out to be unrelated to the shared one.
        var origin: CMTime?
        var started = false
    }

    /// Peak (0...1) of the left and right channel as written, i.e. after processing.
    var onLevels: ((Float, Float) -> Void)?
    /// Seconds of speech heard on each side so far; nil without a processor.
    var speechSeconds: (left: Double, right: Double)? { processor?.speechSeconds }

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let processor: StereoProcessor?
    private var left = Track()
    private var right = Track()
    private var origin: CMTime?
    private var written = 0

    /// Writes the lossless capture (see RecordingFile).
    init(url: URL, processor: StereoProcessor?) throws {
        self.processor = processor
        // FLAC takes its bit depth from the buffers it is handed, and float input becomes
        // 24-bit, which spends a third of the file on noise. Feed it 16-bit integers.
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                               channels: 2, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: RecordingFile.captureSettings,
                               commonFormat: .pcmFormatInt16, interleaved: false)
    }

    func append(_ mono: [Float], pts: CMTime, to channel: Channel) throws {
        guard !mono.isEmpty else { return }
        if origin == nil { origin = pts }

        var track = channel == .left ? left : right
        let end = written + track.samples.count
        var expected = index(of: pts, origin: track.origin ?? origin!)

        var tolerance = Self.tolerance
        if !track.started {
            track.started = true
            // Timestamps from a different clock: pin this stream to "now" instead.
            if abs(expected - end) > Int(Self.sampleRate * 5) {
                let shift = CMTime(value: CMTimeValue(end), timescale: CMTimeScale(Self.sampleRate))
                track.origin = pts - shift
                expected = end
            }
            // Place the first buffer exactly: an offset accepted here would shift the whole
            // stream against the other one for the rest of the recording.
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

        // The processor works on whole blocks; at the end the last one is padded with silence.
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
