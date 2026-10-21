import AVFoundation

final class TonePlayer {
    private static let sampleRate = 48_000.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init?() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else { return nil }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func play(_ samples: [Float], looping: Bool = false) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        for (frame, sample) in samples.enumerated() { channel[frame] = sample }
        player.scheduleBuffer(buffer, at: nil, options: looping ? .loops : [])
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    static func tone(frequency: Double, amplitude: Double, seconds: Double) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { frame in
            Float(amplitude * sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }

    static var chime: [Float] {
        let secondNote = Int(sampleRate * 0.15)
        return (0..<Int(sampleRate * 0.9)).map { frame in
            let first = bell(880, at: Double(frame) / sampleRate)
            let second = frame < secondNote ? 0 : bell(1_318.5, at: Double(frame - secondNote) / sampleRate)
            return first + second
        }
    }

    private static func bell(_ frequency: Double, at time: Double) -> Float {
        Float(0.1 * min(time / 0.005, 1) * exp(-time * 7) * sin(2 * .pi * frequency * time))
    }
}
