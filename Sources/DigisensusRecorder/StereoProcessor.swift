import Accelerate
import Foundation

final class StereoProcessor {
    static let blockSize = 480
    private static let blockSeconds = Float(blockSize) / 48_000

    private static let leakMarginDB: Float = 12
    private static let holdSeconds: Float = 0.5
    private static let duckDB: Float = -60
    private static let duckDownDBPerSecond: Float = 3_000
    private static let duckUpDBPerSecond: Float = 1_200
    private static let envelopeReleaseDBPerSecond: Float = 100
    private static let absoluteGateDB: Float = -66
    private static let gateMarginDB: Float = 9

    private static let maxBleedLag = 48_000 / 4
    private static let lagSearchBlocks = 100
    private static let lagWindow = 48
    private static let bleedCorrelation: Float = 0.5
    private static let bleedCorrelationHold: Float = 0.35
    private static let toneFlatness: Float = 0.002

    private struct Side {
        var envelopeDB: Float = -100
        var noiseDB: Float = -60
        var speechDB: Float?
        var confirmed = false
        var activeBlocks = 0
        var gainDB: Float = 0
        var leveler: Leveler?

        var isActive: Bool { activeBlocks > 0 }

        var isLeak: Bool {
            guard let speechDB, confirmed else { return true }
            return envelopeDB - speechDB < -StereoProcessor.leakMarginDB
        }

        var isTalking: Bool { isActive && !isLeak }

        mutating func track(_ rmsDB: Float) -> Bool {
            envelopeDB = max(rmsDB, envelopeDB - StereoProcessor.envelopeReleaseDBPerSecond * StereoProcessor.blockSeconds)
            if rmsDB < noiseDB {
                noiseDB += (rmsDB - noiseDB) * 0.3
            } else {
                noiseDB += 1.5 * StereoProcessor.blockSeconds
            }
            let voiced = rmsDB > StereoProcessor.absoluteGateDB && rmsDB > noiseDB + StereoProcessor.gateMarginDB
            if voiced {
                activeBlocks = Int(StereoProcessor.holdSeconds / StereoProcessor.blockSeconds)
            } else if activeBlocks > 0 {
                activeBlocks -= 1
            }
            return voiced
        }

        mutating func learn(_ rmsDB: Float, otherActive: Bool) {
            if !otherActive { confirmed = true }
            guard let current = speechDB else {
                speechDB = rmsDB
                return
            }
            if rmsDB > current {
                speechDB = current + (rmsDB - current) * min(1, StereoProcessor.blockSeconds / 0.4)
            } else if !isLeak || !otherActive {
                speechDB = current + (rmsDB - current) * min(1, StereoProcessor.blockSeconds / 6)
            }
        }
    }

    private var left = Side()
    private var right = Side()
    private let gate: Bool

    private var leftHistory = [Float](repeating: 0, count: StereoProcessor.maxBleedLag + StereoProcessor.blockSize)
    private var correlations = [Float](repeating: 0, count: StereoProcessor.maxBleedLag + 1)
    private var bleedLag: Int?
    private var blocksSinceSearch = StereoProcessor.lagSearchBlocks
    private var wasBleed = false

    private(set) var speechSeconds = (left: 0.0, right: 0.0)
    private let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: StereoProcessor.blockSize, isHalfWindow: false)
    private var windowed = [Float](repeating: 0, count: 512)
    private var fftInReal = [Float](repeating: 0, count: 256)
    private var fftInImag = [Float](repeating: 0, count: 256)
    private var fftOutReal = [Float](repeating: 0, count: 256)
    private var fftOutImag = [Float](repeating: 0, count: 256)

    init(levelling: Bool, gate: Bool) {
        self.gate = gate
        if levelling {
            left.leveler = Leveler()
            right.leveler = Leveler()
        }
    }

    func process(left l: UnsafeMutableBufferPointer<Float>, right r: UnsafeMutableBufferPointer<Float>) {
        precondition(l.count == Self.blockSize && r.count == Self.blockSize)
        let rmsL = Self.rmsDB(l)
        let rmsR = Self.rmsDB(r)
        let wasActiveL = left.isActive
        let wasActiveR = right.isActive
        let voicedL = left.track(rmsL)
        let voicedR = right.track(rmsR)

        leftHistory.removeFirst(Self.blockSize)
        leftHistory.append(contentsOf: l)
        let bleed = gate && bleedFromSpeakers(mic: r, voicedR: voicedR)

        if voicedL { left.learn(rmsL, otherActive: wasActiveR) }
        if voicedR, !bleed { right.learn(rmsR, otherActive: wasActiveL) }

        let talkingL = left.isTalking
        let talkingR = right.isTalking
        let duckL = gate && talkingR && left.isLeak
        let duckR = gate && ((talkingL && right.isLeak) || bleed)
        if talkingL, !duckL, flatness(l) >= Self.toneFlatness { speechSeconds.left += Double(Self.blockSeconds) }
        if talkingR, !duckR, !bleed, flatness(r) >= Self.toneFlatness { speechSeconds.right += Double(Self.blockSeconds) }
        Self.apply(&left, to: l, duck: duckL, otherTalking: talkingR)
        Self.apply(&right, to: r, duck: duckR, otherTalking: talkingL || bleed)
    }

    private func flatness(_ block: UnsafeMutableBufferPointer<Float>) -> Float {
        vDSP_vmul(block.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(Self.blockSize))
        for i in 0..<256 {
            fftInReal[i] = windowed[2 * i]
            fftInImag[i] = windowed[2 * i + 1]
        }
        fftInReal.withUnsafeMutableBufferPointer { inR in
            fftInImag.withUnsafeMutableBufferPointer { inI in
                fftOutReal.withUnsafeMutableBufferPointer { outR in
                    fftOutImag.withUnsafeMutableBufferPointer { outI in
                        let input = DSPSplitComplex(realp: inR.baseAddress!, imagp: inI.baseAddress!)
                        var output = DSPSplitComplex(realp: outR.baseAddress!, imagp: outI.baseAddress!)
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }
        var logSum: Float = 0
        var sum: Float = 0
        for bin in 1...42 {
            let power = fftOutReal[bin] * fftOutReal[bin] + fftOutImag[bin] * fftOutImag[bin] + 1e-12
            logSum += log(power)
            sum += power
        }
        return exp(logSum / 42) / (sum / 42)
    }

    private func bleedFromSpeakers(mic: UnsafeMutableBufferPointer<Float>, voicedR: Bool) -> Bool {
        guard left.isActive, voicedR else {
            wasBleed = false
            return false
        }
        blocksSinceSearch += 1
        var lags: ClosedRange<Int>
        if let bleedLag, blocksSinceSearch < Self.lagSearchBlocks || right.isTalking {
            lags = max(0, bleedLag - Self.lagWindow)...min(Self.maxBleedLag, bleedLag + Self.lagWindow)
        } else {
            lags = 0...Self.maxBleedLag
            blocksSinceSearch = 0
        }
        let (lag, correlation) = Self.bestCorrelation(of: mic, against: leftHistory, lags: lags, scratch: &correlations)
        if lags.count > 2 * Self.lagWindow + 1, correlation > Self.bleedCorrelation {
            bleedLag = lag
        }
        let threshold = wasBleed ? Self.bleedCorrelationHold : Self.bleedCorrelation
        wasBleed = correlation > threshold
        return wasBleed
    }

    private static func bestCorrelation(of block: UnsafeMutableBufferPointer<Float>, against history: [Float],
                                        lags: ClosedRange<Int>, scratch: inout [Float]) -> (Int, Float) {
        let n = block.count
        var blockEnergy: Float = 0
        vDSP_dotpr(block.baseAddress!, 1, block.baseAddress!, 1, &blockEnergy, vDSP_Length(n))
        guard blockEnergy > 0 else { return (lags.lowerBound, 0) }

        let first = history.count - n - lags.upperBound
        let count = lags.count
        history.withUnsafeBufferPointer { h in
            scratch.withUnsafeMutableBufferPointer { out in
                vDSP_conv(h.baseAddress! + first, 1, block.baseAddress!, 1, out.baseAddress!, 1,
                          vDSP_Length(count), vDSP_Length(n))
            }
        }
        var energy: Float = 0
        var best: (Int, Float) = (lags.lowerBound, 0)
        history.withUnsafeBufferPointer { h in
            vDSP_dotpr(h.baseAddress! + first, 1, h.baseAddress! + first, 1, &energy, vDSP_Length(n))
            for i in 0..<count {
                if i > 0 {
                    let leaving = h[first + i - 1]
                    let entering = h[first + i - 1 + n]
                    energy += entering * entering - leaving * leaving
                }
                guard energy > 1e-9 else { continue }
                let c = abs(scratch[i]) / (blockEnergy * energy).squareRoot()
                if c > best.1 { best = (lags.upperBound - i, c) }
            }
        }
        return best
    }

    private static func apply(_ side: inout Side, to block: UnsafeMutableBufferPointer<Float>,
                              duck: Bool, otherTalking: Bool) {
        let wanted: Float = duck ? duckDB : 0
        let rate = wanted < side.gainDB ? duckDownDBPerSecond : duckUpDBPerSecond
        let step = rate * blockSeconds
        let previous = side.gainDB
        side.gainDB += max(-step, min(step, wanted - side.gainDB))
        if previous != 0 || side.gainDB != 0 {
            let from = pow(10, previous / 20)
            let to = pow(10, side.gainDB / 20)
            let count = Float(block.count)
            for index in block.indices {
                block[index] *= from + (to - from) * Float(index) / count
            }
        }
        side.leveler?.apply(to: block, adapt: !duck && !otherTalking && !side.isLeak)
    }

    private static func rmsDB(_ block: UnsafeMutableBufferPointer<Float>) -> Float {
        var sum: Float = 0
        for sample in block { sum += sample * sample }
        return 10 * log10(max(sum / Float(block.count), 1e-12))
    }
}
