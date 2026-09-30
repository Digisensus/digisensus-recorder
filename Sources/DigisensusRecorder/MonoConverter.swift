import AVFoundation
import CoreMedia

/// Turns whatever ScreenCaptureKit delivers into 48 kHz mono Float32.
/// Samples are read straight from the buffer list using the stream description, because
/// AVAudioFormat can't represent every device format (e.g. multichannel without a layout).
final class MonoConverter {
    enum Downmix {
        /// Average all channels (app audio).
        case average
        /// Use the first channel only (mics on multi-input interfaces).
        case first
    }

    private let downmix: Downmix
    private var resampler: AVAudioConverter?
    private var resamplerRate: Double = 0
    private var loggedFormat: AudioStreamBasicDescription?

    init(downmix: Downmix) {
        self.downmix = downmix
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        if loggedFormat?.mSampleRate != asbd.mSampleRate || loggedFormat?.mChannelsPerFrame != asbd.mChannelsPerFrame {
            loggedFormat = asbd
            Log.write("\(downmix == .first ? "mic" : "app") input: \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, "
                + "\(asbd.mBitsPerChannel) bit, flags 0x\(String(asbd.mFormatFlags, radix: 16))")
        }
        var result: [Float]?
        try? sampleBuffer.withAudioBufferList { list, _ in
            result = convert(list, asbd: asbd, frames: sampleBuffer.numSamples)
        }
        return result
    }

    /// `frames` defaults to whatever the first buffer holds.
    func convert(_ list: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription,
                 frames: Int? = nil) -> [Float]? {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              let mono = mono(from: list, asbd: asbd, frames: frames) else { return nil }
        if asbd.mSampleRate == StereoWriter.sampleRate { return mono }
        return resample(mono, from: asbd.mSampleRate)
    }

    private func mono(from list: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription,
                      frames: Int?) -> [Float]? {
        let channels = Int(asbd.mChannelsPerFrame)
        let bits = Int(asbd.mBitsPerChannel)
        guard channels > 0, bits > 0, list.count > 0 else { return nil }

        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let stride = interleaved ? channels : 1
        let frames = frames ?? Int(list[0].mDataByteSize) / (bits / 8 * stride)
        guard frames > 0 else { return nil }
        let used = downmix == .first ? 1 : channels

        var result = [Float](repeating: 0, count: frames)
        for channel in 0..<used {
            let buffer = interleaved ? list[0] : list[min(channel, list.count - 1)]
            let offset = interleaved ? channel : 0
            guard let data = buffer.mData,
                  Int(buffer.mDataByteSize) >= ((frames - 1) * stride + offset + 1) * bits / 8 else { return nil }
            switch (isFloat, bits) {
            case (true, 32):
                let samples = data.assumingMemoryBound(to: Float32.self)
                for frame in 0..<frames { result[frame] += samples[frame * stride + offset] }
            case (true, 64):
                let samples = data.assumingMemoryBound(to: Float64.self)
                for frame in 0..<frames { result[frame] += Float(samples[frame * stride + offset]) }
            case (false, 16):
                let samples = data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frames { result[frame] += Float(samples[frame * stride + offset]) / 32_768 }
            case (false, 32):
                let samples = data.assumingMemoryBound(to: Int32.self)
                for frame in 0..<frames { result[frame] += Float(samples[frame * stride + offset]) / 2_147_483_648 }
            default:
                return nil
            }
        }

        if used > 1 {
            let scale = 1 / Float(used)
            for frame in 0..<frames { result[frame] *= scale }
        }
        return result
    }

    private func resample(_ mono: [Float], from rate: Double) -> [Float]? {
        guard rate > 0,
              let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: StereoWriter.sampleRate, channels: 1)
        else { return nil }
        if resampler == nil || resamplerRate != rate {
            resampler = AVAudioConverter(from: input, to: output)
            resamplerRate = rate
        }
        guard let resampler,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(mono.count)),
              let inData = inBuffer.floatChannelData else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { inData[0].update(from: $0.baseAddress!, count: mono.count) }

        let capacity = AVAudioFrameCount((Double(mono.count) * StereoWriter.sampleRate / rate).rounded(.up)) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = resampler.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, let outData = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: outData[0], count: Int(outBuffer.frameLength)))
    }
}
