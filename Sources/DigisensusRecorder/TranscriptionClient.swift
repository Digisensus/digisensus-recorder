import AVFoundation
import Foundation

struct TranscriptionSettings: Equatable {
    /// A speech-to-text server on this Mac, the usual first try.
    static let defaultServer = "http://localhost:8000"

    var provider = AIProvider.digisensus
    var server = TranscriptionSettings.defaultServer
    var apiKey = ""
    var model = "whisper-1"
    /// ISO-639-1 code, or empty to let the server detect it.
    var language = ""
}

struct TranscriptionResult {
    struct Turn {
        let channel: TranscriptSegment.Channel
        let start: Double
        let end: Double
        let text: String
    }

    var turns: [Turn]
    var language: String?
}

enum TranscriptionError: LocalizedError {
    case badServerURL
    case server(Int, String)
    case unreadableResponse
    case unsplittable(String)

    var errorDescription: String? {
        switch self {
        case .badServerURL: return "The transcription server address isn't a valid URL."
        case .server(let code, let detail) where AIProvider.explainsRefusal(status: code): return detail
        case .server(let code, let detail): return "The transcription server answered \(code): \(detail)"
        case .unreadableResponse: return "The transcription server sent a response the app doesn't understand."
        case .unsplittable(let detail):
            return "This server doesn't separate speakers, and the recording's channels couldn't be split: \(detail)"
        }
    }
}

/// Talks to an OpenAI-compatible `/v1/audio/transcriptions` endpoint.
///
/// Servers that understand stereo call recordings (they label turns "Agent"/"Customer" when
/// told which channel the agent is on) get the file as it is. Plain Whisper-style servers
/// return unlabelled segments, so for those each channel is transcribed on its own.
struct TranscriptionClient {
    let settings: TranscriptionSettings

    func transcribe(_ file: URL) async throws -> TranscriptionResult {
        let response = try await request(file, extraFields: ["agent_channel": "right"])
        if let labelled = Self.labelledTurns(in: response) {
            return TranscriptionResult(turns: Self.coalesced(labelled), language: Self.language(in: response))
        }

        // No speaker labels: the right channel is the microphone, the left the other side.
        var turns: [TranscriptionResult.Turn] = []
        for (index, channel) in [TranscriptSegment.Channel.them, .me].enumerated() {
            let mono = try Self.extractChannel(index, of: file)
            defer { try? FileManager.default.removeItem(at: mono) }
            turns += Self.segments(in: try await request(mono, extraFields: [:]), channel: channel)
        }
        return TranscriptionResult(turns: Self.coalesced(turns.sorted { $0.start < $1.start }),
                                   language: Self.language(in: response))
    }

    /// Cheap reachability check for the settings screen.
    func checkConnection() async -> String {
        guard let base = URL(string: settings.server) else { return "Not a valid URL." }
        for path in ["health", "v1/models"] {
            var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 6)
            request.authorize(apiKey: settings.apiKey, provider: settings.provider)
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return "Connected."
            }
        }
        return "No answer from \(settings.server)."
    }

    // MARK: Request

    private func request(_ file: URL, extraFields: [String: String]) async throws -> [String: Any] {
        guard let base = URL(string: settings.server), base.scheme != nil else { throw TranscriptionError.badServerURL }
        var fields = ["model": settings.model, "response_format": "verbose_json",
                      "timestamp_granularities[]": "segment"]
        if !settings.language.isEmpty { fields["language"] = settings.language }
        fields.merge(extraFields) { $1 }

        // The multipart body goes through a file so long recordings aren't held in memory.
        let boundary = "digisensus-recorder-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeMultipart(to: body, boundary: boundary, fields: fields, file: file)

        var request = URLRequest(url: base.appendingPathComponent("v1/audio/transcriptions"),
                                 timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.authorize(apiKey: settings.apiKey, provider: settings.provider)

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            AppVersion.noteRefusal(status: status)
            throw TranscriptionError.server(status, detail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.unreadableResponse
        }
        return json
    }

    private static func writeMultipart(to url: URL, boundary: String, fields: [String: String], file: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try output.write(contentsOf: Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n").utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    // MARK: Response

    private static func language(in response: [String: Any]) -> String? {
        (response["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Speaker-labelled turns, from `dialogue` (finest) or labelled `segments`; nil when the
    /// server doesn't label speakers at all.
    private static func labelledTurns(in response: [String: Any]) -> [TranscriptionResult.Turn]? {
        for key in ["dialogue", "segments"] {
            guard let items = response[key] as? [[String: Any]], !items.isEmpty,
                  items.allSatisfy({ $0["speaker"] is String }) else { continue }
            return items.compactMap { item in
                // The agent was declared to be on the right channel, which is the microphone.
                let isMe = (item["speaker"] as? String)?.lowercased() == "agent"
                return turn(from: item, channel: isMe ? .me : .them)
            }
        }
        return nil
    }

    private static func segments(in response: [String: Any], channel: TranscriptSegment.Channel) -> [TranscriptionResult.Turn] {
        if let items = response["segments"] as? [[String: Any]], !items.isEmpty {
            // Whisper marks hallucinated text over silence with a high no-speech probability.
            return items.filter { ($0["no_speech_prob"] as? Double ?? 0) < 0.8 }
                .compactMap { turn(from: $0, channel: channel) }
        }
        // A server without timestamps still gives the text; keep it as one turn.
        let text = (response["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = response["duration"] as? Double ?? 0
        return text.isEmpty ? [] : [.init(channel: channel, start: 0, end: duration, text: text)]
    }

    /// Servers tend to return a fragment per phrase; join what one speaker says without
    /// interruption into a paragraph, as long as it stays a readable size.
    private static func coalesced(_ turns: [TranscriptionResult.Turn]) -> [TranscriptionResult.Turn] {
        var result: [TranscriptionResult.Turn] = []
        for turn in turns {
            if let last = result.last, last.channel == turn.channel,
               turn.start - last.end <= 1.5, last.text.count + turn.text.count < 400 {
                result[result.count - 1] = .init(channel: last.channel, start: last.start,
                                                 end: max(last.end, turn.end), text: last.text + " " + turn.text)
            } else {
                result.append(turn)
            }
        }
        return result
    }

    private static func turn(from item: [String: Any], channel: TranscriptSegment.Channel) -> TranscriptionResult.Turn? {
        let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let start = item["start"] as? Double ?? 0
        return .init(channel: channel, start: start, end: item["end"] as? Double ?? start, text: text)
    }

    // MARK: Channel splitting

    /// One channel on its own, as mono Ogg Opus: the recording's own format, which the
    /// Digisensus service requires and OpenAI-compatible servers accept.
    private static func extractChannel(_ index: Int, of file: URL) throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("digisensus-recorder-channel\(index)-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        do {
            let encoder = try OggOpusEncoder(url: output, channels: 1, bitrate: RecordingFile.monoOpusBitrate)
            var mono: [Float] = []
            try OggOpusDecoder.decode(file) { samples, frames in
                let channels = samples.count / frames
                guard index < channels else { throw TranscriptionError.unsplittable("no channel \(index)") }
                mono.removeAll(keepingCapacity: true)
                mono.reserveCapacity(frames)
                for frame in 0..<frames { mono.append(samples[frame * channels + index]) }
                try mono.withUnsafeBufferPointer { try encoder.append($0) }
            }
            try encoder.finish()
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw (error as? TranscriptionError) ?? TranscriptionError.unsplittable(error.localizedDescription)
        }
        return output
    }
}
