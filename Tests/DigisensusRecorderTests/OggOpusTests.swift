import Foundation
import Testing
@testable import DigisensusRecorder

struct OggOpusTests {
    @Test func stereoRoundTripKeepsLengthAndChannels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opus-test-\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = 72_000
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames { interleaved[frame * 2] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000) }
        let encoder = try OggOpusEncoder(url: url, channels: 2, bitrate: RecordingFile.opusBitrate)
        try interleaved.withUnsafeBufferPointer { try encoder.append($0) }
        try encoder.finish()

        #expect(OggOpusDecoder.duration(of: url).map { abs($0 - 1.5) < 0.001 } == true)

        var decodedFrames = 0
        var leftEnergy: Float = 0
        var rightEnergy: Float = 0
        let info = try OggOpusDecoder.decode(url) { samples, count in
            decodedFrames += count
            for frame in 0..<count {
                leftEnergy += samples[frame * 2] * samples[frame * 2]
                rightEnergy += samples[frame * 2 + 1] * samples[frame * 2 + 1]
            }
        }
        #expect(info.channels == 2)
        #expect(info.family == 255, "each channel is its own stream")
        #expect(decodedFrames == frames)
        #expect(leftEnergy > 1000)
        #expect(rightEnergy < leftEnergy / 1000, "the silent channel stays silent: no coupling between the sides")
    }

    @Test func rejectsAFileThatIsNotOggOpus() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-opus-\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)
        #expect(OggOpusDecoder.duration(of: url) == nil)
        #expect(throws: OggOpusError.self) { try OggOpusDecoder.decode(url) { _, _ in } }
    }
}
