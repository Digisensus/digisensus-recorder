import AVFoundation
import COpusShim
import Foundation

enum OggOpusError: LocalizedError {
    case opus(String, Int32)
    case ogg(String)
    case notOggOpus
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .opus(let step, let code): return "Opus couldn't \(step) (\(String(cString: opus_strerror(code))))."
        case .ogg(let step): return "Ogg couldn't \(step)."
        case .notOggOpus: return "This isn't an Ogg Opus file."
        case .unsupported(let what): return "Unsupported Ogg Opus file: \(what)."
        }
    }
}

final class OggOpusEncoder {
    static let sampleRate: Double = 48_000
    static let frameSize = 960

    private let channels: Int
    private let encoder: OpaquePointer
    private var stream = ogg_stream_state()
    private let handle: FileHandle
    private let preSkip: Int
    private var carry: [Float] = []
    private var samplesIn = 0
    private var framesOut = 0
    private var packetNumber: Int64 = 0
    private var packetBuffer = [UInt8](repeating: 0, count: 1276 * 8)
    private var finished = false

    init(url: URL, channels: Int, bitrate: Int) throws {
        precondition(channels >= 1 && channels <= 8)
        self.channels = channels
        let mapping = (0..<channels).map(UInt8.init)
        var status: Int32 = 0
        guard let encoder = opus_multistream_encoder_create(
            opus_int32(Self.sampleRate), Int32(channels), Int32(channels), 0, mapping, OPUS_APPLICATION_VOIP, &status),
            status == OPUS_OK else { throw OggOpusError.opus("create an encoder", status) }
        self.encoder = encoder
        copus_ms_encoder_set_bitrate(encoder, Int32(bitrate))
        copus_ms_encoder_set_vbr(encoder, 1)
        copus_ms_encoder_set_signal_voice(encoder)
        copus_ms_encoder_set_complexity(encoder, 10)
        copus_ms_encoder_set_max_bandwidth_wideband(encoder)
        var lookahead: Int32 = 0
        copus_ms_encoder_get_lookahead(encoder, &lookahead)
        preSkip = Int(lookahead)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        guard ogg_stream_init(&stream, Int32.random(in: 1...Int32.max)) == 0 else {
            opus_multistream_encoder_destroy(encoder)
            throw OggOpusError.ogg("start a stream")
        }
        try writePacket(header(), granule: 0, first: true, last: false)
        try flushPages(force: true)
        try writePacket(tags(), granule: 0, first: false, last: false)
        try flushPages(force: true)
    }

    deinit {
        if !finished { ogg_stream_clear(&stream) }
        opus_multistream_encoder_destroy(encoder)
    }

    func append(_ interleaved: UnsafeBufferPointer<Float>) throws {
        carry.append(contentsOf: interleaved)
        samplesIn += interleaved.count / channels
        try encodeCarry(padToFrame: false, last: false)
    }

    func finish() throws {
        guard !finished else { return }
        let wanted = samplesIn + preSkip
        var padding = ((wanted + Self.frameSize - 1) / Self.frameSize) * Self.frameSize - framesOut * Self.frameSize
            - carry.count / channels
        if padding < 0 { padding = 0 }
        carry.append(contentsOf: repeatElement(0, count: padding * channels))
        try encodeCarry(padToFrame: true, last: true)
        try flushPages(force: true)
        try handle.close()
        ogg_stream_clear(&stream)
        finished = true
    }

    private func encodeCarry(padToFrame: Bool, last: Bool) throws {
        let frameSamples = Self.frameSize * channels
        let finalGranule = Int64(samplesIn + preSkip)
        var offset = 0
        while carry.count - offset >= frameSamples {
            let isLast = last && carry.count - offset - frameSamples < frameSamples
            let bytes = carry.withUnsafeBufferPointer { pcm in
                packetBuffer.withUnsafeMutableBufferPointer { out in
                    opus_multistream_encode_float(encoder, pcm.baseAddress! + offset, Int32(Self.frameSize),
                                                  out.baseAddress!, opus_int32(out.count))
                }
            }
            guard bytes > 0 else { throw OggOpusError.opus("encode a frame", bytes) }
            framesOut += 1
            let granule = min(Int64(framesOut * Self.frameSize), isLast ? finalGranule : .max)
            try writePacket(Array(packetBuffer.prefix(Int(bytes))), granule: granule, first: false, last: isLast)
            try flushPages(force: false)
            offset += frameSamples
        }
        carry.removeFirst(offset)
    }

    private func writePacket(_ bytes: [UInt8], granule: Int64, first: Bool, last: Bool) throws {
        var bytes = bytes
        var packet = ogg_packet()
        let status: Int32 = bytes.withUnsafeMutableBufferPointer { buffer in
            packet.packet = buffer.baseAddress
            packet.bytes = buffer.count
            packet.b_o_s = first ? 1 : 0
            packet.e_o_s = last ? 1 : 0
            packet.granulepos = granule
            packet.packetno = packetNumber
            return ogg_stream_packetin(&stream, &packet)
        }
        guard status == 0 else { throw OggOpusError.ogg("add a packet") }
        packetNumber += 1
    }

    private func flushPages(force: Bool) throws {
        var page = ogg_page()
        while (force ? ogg_stream_flush(&stream, &page) : ogg_stream_pageout(&stream, &page)) != 0 {
            try handle.write(contentsOf: Data(bytes: page.header, count: page.header_len))
            try handle.write(contentsOf: Data(bytes: page.body, count: page.body_len))
        }
    }

    private func header() -> [UInt8] {
        var data = Array("OpusHead".utf8)
        data.append(1)
        data.append(UInt8(channels))
        data += Self.littleEndian(UInt16(preSkip))
        data += Self.littleEndian(UInt32(Self.sampleRate))
        data += Self.littleEndian(UInt16(0))
        data.append(255)
        data.append(UInt8(channels))
        data.append(0)
        data += (0..<channels).map(UInt8.init)
        return data
    }

    private func tags() -> [UInt8] {
        let vendor = Array(String(cString: opus_get_version_string()).utf8)
        return Array("OpusTags".utf8) + Self.littleEndian(UInt32(vendor.count)) + vendor + Self.littleEndian(UInt32(0))
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
}

enum OggOpusDecoder {
    struct Info {
        let channels: Int
        let preSkip: Int
        let family: UInt8
        let streams: Int
        let coupled: Int
        let mapping: [UInt8]
    }

    @discardableResult
    static func decode(_ url: URL, sink: (UnsafeBufferPointer<Float>, _ frames: Int) throws -> Void) throws -> Info {
        var info: Info?
        var decoder: OpaquePointer?
        var multistream = false
        var pcm: [Float] = []
        var decoded = 0
        defer {
            if let decoder {
                multistream ? opus_multistream_decoder_destroy(decoder) : opus_decoder_destroy(decoder)
            }
        }

        try readPages(url) { page, packets in
            for (index, packet) in packets.enumerated() {
                if info == nil {
                    let parsed = try parseHeader(packet)
                    info = parsed
                    var status: Int32 = 0
                    if parsed.family == 0 {
                        decoder = opus_decoder_create(48_000, Int32(parsed.channels), &status)
                    } else {
                        multistream = true
                        decoder = opus_multistream_decoder_create(48_000, Int32(parsed.channels), Int32(parsed.streams),
                                                                  Int32(parsed.coupled), parsed.mapping, &status)
                    }
                    guard decoder != nil, status == OPUS_OK else { throw OggOpusError.opus("create a decoder", status) }
                    pcm = [Float](repeating: 0, count: 5760 * parsed.channels)
                    continue
                }
                guard let info, let decoder else { continue }
                if packet.starts(with: Array("OpusTags".utf8)) { continue }

                let frames = packet.withUnsafeBufferPointer { data in
                    pcm.withUnsafeMutableBufferPointer { out in
                        multistream
                            ? opus_multistream_decode_float(decoder, data.baseAddress, opus_int32(data.count),
                                                            out.baseAddress!, 5760, 0)
                            : opus_decode_float(decoder, data.baseAddress, opus_int32(data.count), out.baseAddress!, 5760, 0)
                    }
                }
                guard frames >= 0 else { throw OggOpusError.opus("decode a frame", frames) }

                var start = 0
                var count = Int(frames)
                if decoded < info.preSkip {
                    start = min(count, info.preSkip - decoded)
                    count -= start
                }
                let granule = ogg_page_granulepos(page)
                if index == packets.count - 1, granule >= 0 {
                    let allowed = Int(granule) - decoded - start
                    if allowed < count { count = max(0, allowed) }
                }
                decoded += Int(frames)
                if count > 0 {
                    try pcm.withUnsafeBufferPointer { buffer in
                        try sink(UnsafeBufferPointer(rebasing: buffer[start * info.channels..<(start + count) * info.channels]), count)
                    }
                }
            }
        }
        guard let info else { throw OggOpusError.notOggOpus }
        return info
    }

    static func duration(of url: URL) -> Double? {
        var preSkip: Int?
        var last: Int64 = -1
        do {
            try readPages(url) { page, packets in
                if preSkip == nil, let first = packets.first { preSkip = try parseHeader(first).preSkip }
                let granule = ogg_page_granulepos(page)
                if granule > last { last = granule }
            }
        } catch {
            return nil
        }
        guard let preSkip, last >= 0 else { return nil }
        return Double(max(0, Int(last) - preSkip)) / 48_000
    }

    private static func readPages(_ url: URL, body: (UnsafeMutablePointer<ogg_page>, [[UInt8]]) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sync = ogg_sync_state()
        var stream = ogg_stream_state()
        var page = ogg_page()
        var packet = ogg_packet()
        var serial: Int32?
        ogg_sync_init(&sync)
        defer {
            ogg_sync_clear(&sync)
            if serial != nil { ogg_stream_clear(&stream) }
        }

        var sawPage = false
        while true {
            let chunk = handle.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            guard let buffer = ogg_sync_buffer(&sync, chunk.count) else { throw OggOpusError.ogg("buffer the file") }
            chunk.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: chunk.count)
            ogg_sync_wrote(&sync, chunk.count)

            while ogg_sync_pageout(&sync, &page) == 1 {
                sawPage = true
                let pageSerial = ogg_page_serialno(&page)
                if serial == nil {
                    guard ogg_page_bos(&page) != 0 else { throw OggOpusError.notOggOpus }
                    ogg_stream_init(&stream, pageSerial)
                    serial = pageSerial
                }
                guard pageSerial == serial else { continue }
                ogg_stream_pagein(&stream, &page)
                var packets: [[UInt8]] = []
                while ogg_stream_packetout(&stream, &packet) == 1 {
                    packets.append(Array(UnsafeBufferPointer(start: packet.packet, count: packet.bytes)))
                }
                try body(&page, packets)
            }
        }
        guard sawPage else { throw OggOpusError.notOggOpus }
    }

    private static func parseHeader(_ packet: [UInt8]) throws -> Info {
        guard packet.count >= 19, packet.starts(with: Array("OpusHead".utf8)) else { throw OggOpusError.notOggOpus }
        let channels = Int(packet[9])
        let preSkip = Int(packet[10]) | Int(packet[11]) << 8
        let family = packet[18]
        guard channels > 0 else { throw OggOpusError.unsupported("no channels") }
        if family == 0 {
            guard channels <= 2 else { throw OggOpusError.unsupported("\(channels) channels in family 0") }
            return Info(channels: channels, preSkip: preSkip, family: 0, streams: 1, coupled: channels - 1,
                        mapping: channels == 1 ? [0] : [0, 1])
        }
        guard packet.count >= 21 + channels else { throw OggOpusError.unsupported("truncated header") }
        return Info(channels: channels, preSkip: preSkip, family: family, streams: Int(packet[19]),
                    coupled: Int(packet[20]), mapping: Array(packet[21..<21 + channels]))
    }
}

final class PCMFileWriter {
    private let file: AVAudioFile
    private let input: AVAudioFormat
    private let converter: AVAudioConverter
    private let channels: Int

    init(url: URL, settings: [String: Any], channels: Int) throws {
        self.channels = channels
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                        channels: AVAudioChannelCount(channels), interleaved: true),
              let sampleRate = settings[AVSampleRateKey] as? Double,
              let output = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        else { throw OggOpusError.unsupported("output format") }
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw OggOpusError.unsupported("conversion to \(Int(sampleRate)) Hz")
        }
        self.input = input
        self.converter = converter
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) throws {
        guard frames > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)),
              let data = inBuffer.floatChannelData else { return }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        data[0].update(from: interleaved.baseAddress!, count: frames * channels)

        let ratio = converter.outputFormat.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error, let error { throw error }
        if outBuffer.frameLength > 0 { try file.write(from: outBuffer) }
    }

    func finish() {
        file.close()
    }
}
