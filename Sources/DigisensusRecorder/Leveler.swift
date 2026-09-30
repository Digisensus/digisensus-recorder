import Foundation

/// Automatic gain control for one speech channel, fed 10 ms blocks. Tracks the level of the
/// voiced parts only, so pauses don't pump the noise floor up, and steers the gain
/// until speech sits at `targetDB`. A soft limiter catches whatever gets through.
/// Not thread-safe; feed each instance from a single queue.
final class Leveler {
    private static let blockSeconds = Float(StereoProcessor.blockSize) / 48_000

    private static let targetDB: Float = -20
    private static let maxGainDB: Float = 40
    private static let minGainDB: Float = -24
    /// Blocks quieter than this are never treated as speech.
    private static let absoluteGateDB: Float = -66
    /// Speech must clear the tracked noise floor by this much.
    private static let gateMarginDB: Float = 9
    private static let gainDownDBPerSecond: Float = 30
    private static let gainUpDBPerSecond: Float = 8
    /// Used until the gain first reaches its goal, so a recording doesn't open with seconds of quiet speech.
    private static let initialGainDBPerSecond: Float = 60
    private static let limiterKnee: Float = 0.7

    private var gainDB: Float = 0
    private var settled = false
    private var speechBlocks = 0
    private var speechDB: Float?
    private var noiseDB: Float = -60

    /// Levels one block in place. With `adapt` off the current gain is applied but nothing
    /// is learned from the block; used for blocks the crosstalk gate has ducked.
    func apply(to block: UnsafeMutableBufferPointer<Float>, adapt: Bool = true) {
        let previousGain = gainDB
        if adapt { learn(block) }

        // Ramp across the block so gain changes never click.
        let from = pow(10, previousGain / 20)
        let to = pow(10, gainDB / 20)
        let count = Float(block.count)
        for index in block.indices {
            let gain = from + (to - from) * Float(index) / count
            block[index] = Self.limit(block[index] * gain)
        }
    }

    private func learn(_ block: UnsafeMutableBufferPointer<Float>) {
        var sum: Float = 0
        for sample in block { sum += sample * sample }
        let rmsDB = 10 * log10(max(sum / Float(block.count), 1e-12))

        // Noise floor: drops quickly to any quieter block, creeps up slowly otherwise.
        if rmsDB < noiseDB {
            noiseDB += (rmsDB - noiseDB) * 0.3
        } else {
            noiseDB += 1.5 * Self.blockSeconds
        }

        guard rmsDB > Self.absoluteGateDB, rmsDB > noiseDB + Self.gateMarginDB else { return }
        // Follow the louder syllables fast and forget them slowly.
        let current = speechDB ?? rmsDB
        let seconds: Float = rmsDB > current ? 0.15 : 2.5
        let level = current + (rmsDB - current) * min(1, Self.blockSeconds / seconds)
        speechDB = level

        let wanted = min(Self.maxGainDB, max(Self.minGainDB, Self.targetDB - level))
        let rate = !settled ? Self.initialGainDBPerSecond
            : wanted < gainDB ? Self.gainDownDBPerSecond : Self.gainUpDBPerSecond
        let step = rate * Self.blockSeconds
        gainDB += max(-step, min(step, wanted - gainDB))
        // A quiet onset can look on-target by chance; wait for half a second of speech.
        speechBlocks += 1
        if speechBlocks >= 50, abs(wanted - gainDB) < 1 { settled = true }
    }

    private static func limit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }
        let headroom = 1 - limiterKnee
        let limited = limiterKnee + headroom * tanh((magnitude - limiterKnee) / headroom)
        return sample < 0 ? -limited : limited
    }
}
