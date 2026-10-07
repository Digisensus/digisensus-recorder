import AVFoundation
import Foundation

struct TranscriptionSettings: Equatable {
    static let defaultServer = "http://localhost:8000"

    var provider = AIProvider.digisensus
    var server = TranscriptionSettings.defaultServer
    var apiKey = ""
    var model = "whisper-1"
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

struct TranscriptionClient {
    let settings: TranscriptionSettings
    var session: URLSession = .shared

    struct Job: Equatable {
        let id: String
        let pollInterval: Double
    }

    enum Poll {
        case running(waitHint: Double?)
        case done([String: Any])
        case failed(String)
    }

    static func pollDelay(after polls: Int) -> Double? {
        switch polls {
        case ..<100: return 10
        case ..<200: return 30
        case ..<250: return 60
        default: return nil
        }
    }

    static let agentChannel = ["agent_channel": "right"]

    func transcribe(_ file: URL) async throws -> TranscriptionResult {
        let response = try await request(file, extraFields: Self.agentChannel)
        return try await finish(response, file: file) { try await request($0, extraFields: [:]) }
    }

    func submit(_ file: URL) async throws -> Job {
        let (status, json) = try await upload(file, to: "v1/audio/transcriptions/jobs", extraFields: Self.agentChannel)
        guard status == 202, let id = json["id"] as? String, !id.isEmpty else {
            throw TranscriptionError.unreadableResponse
        }
        return Job(id: id, pollInterval: json["poll_interval"] as? Double ?? 10)
    }

    func poll(_ jobID: String) async throws -> Poll {
        guard let base = URL(string: settings.server), base.scheme != nil else { throw TranscriptionError.badServerURL }
        var request = URLRequest(url: base.appendingPathComponent("v1/audio/transcriptions/jobs/\(jobID)"),
                                 timeoutInterval: 60)
        request.authorize(apiKey: settings.apiKey, provider: settings.provider)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 202:
            return .running(waitHint: json?["poll_interval"] as? Double)
        case 200:
            guard let json else { throw TranscriptionError.unreadableResponse }
            if json["status"] as? String == "failed" {
                let message = (json["error"] as? [String: Any])?["message"] as? String
                return .failed(message ?? "Transcription failed. Please try again.")
            }
            return .done(json)
        case 404:
            return .failed("The transcription job is no longer available. Try again.")
        case 429:
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            return .running(waitHint: retry ?? 15)
        default:
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            AppVersion.noteRefusal(status: status)
            throw TranscriptionError.server(status, detail)
        }
    }

    func cancel(_ jobID: String) async {
        guard let base = URL(string: settings.server), base.scheme != nil else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/audio/transcriptions/jobs/\(jobID)"),
                                 timeoutInterval: 20)
        request.httpMethod = "DELETE"
        request.authorize(apiKey: settings.apiKey, provider: settings.provider)
        _ = try? await session.data(for: request)
    }

    func finish(_ response: [String: Any], file: URL,
                transcribeMono: (URL) async throws -> [String: Any]) async throws -> TranscriptionResult {
        if let labelled = Self.labelledTurns(in: response) {
            return TranscriptionResult(turns: Self.coalesced(labelled), language: Self.language(in: response))
        }

        var turns: [TranscriptionResult.Turn] = []
        for (index, channel) in [TranscriptSegment.Channel.them, .me].enumerated() {
            let mono = try Self.extractChannel(index, of: file)
            defer { try? FileManager.default.removeItem(at: mono) }
            turns += Self.segments(in: try await transcribeMono(mono), channel: channel)
        }
        return TranscriptionResult(turns: Self.coalesced(turns.sorted { $0.start < $1.start }),
                                   language: Self.language(in: response))
    }

    func submitAndWait(_ file: URL) async throws -> [String: Any] {
        let job = try await submit(file)
        var polls = 0
        var hint: Double?
        while let delay = Self.pollDelay(after: polls) {
            try await Task.sleep(for: .seconds(max(delay, hint ?? 0)))
            polls += 1
            switch try await poll(job.id) {
            case .running(let waitHint): hint = waitHint
            case .done(let json): return json
            case .failed(let message): throw TranscriptionError.server(200, message)
            }
        }
        await cancel(job.id)
        throw TranscriptionError.server(504, "Transcription did not finish in time.")
    }

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

    private func request(_ file: URL, extraFields: [String: String]) async throws -> [String: Any] {
        let (status, json) = try await upload(file, to: "v1/audio/transcriptions", extraFields: extraFields)
        guard status == 200 else { throw TranscriptionError.unreadableResponse }
        return json
    }

    private func upload(_ file: URL, to path: String, extraFields: [String: String]) async throws -> (Int, [String: Any]) {
        guard let base = URL(string: settings.server), base.scheme != nil else { throw TranscriptionError.badServerURL }
        var fields = ["model": settings.model, "response_format": "verbose_json",
                      "timestamp_granularities[]": "segment"]
        if !settings.language.isEmpty { fields["language"] = settings.language }
        fields.merge(extraFields) { $1 }

        let boundary = "digisensus-recorder-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeMultipart(to: body, boundary: boundary, fields: fields, file: file)

        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.authorize(apiKey: settings.apiKey, provider: settings.provider)

        let (data, response) = try await session.upload(for: request, fromFile: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 202 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            AppVersion.noteRefusal(status: status)
            throw TranscriptionError.server(status, detail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.unreadableResponse
        }
        return (status, json)
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

    private static func language(in response: [String: Any]) -> String? {
        (response["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func labelledTurns(in response: [String: Any]) -> [TranscriptionResult.Turn]? {
        for key in ["dialogue", "segments"] {
            guard let items = response[key] as? [[String: Any]], !items.isEmpty,
                  items.allSatisfy({ $0["speaker"] is String }) else { continue }
            return items.compactMap { item in
                let isMe = (item["speaker"] as? String)?.lowercased() == "agent"
                return turn(from: item, channel: isMe ? .me : .them)
            }
        }
        return nil
    }

    private static func segments(in response: [String: Any], channel: TranscriptSegment.Channel) -> [TranscriptionResult.Turn] {
        if let items = response["segments"] as? [[String: Any]], !items.isEmpty {
            return items.filter { ($0["no_speech_prob"] as? Double ?? 0) < 0.8 }
                .compactMap { turn(from: $0, channel: channel) }
        }
        let text = (response["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = response["duration"] as? Double ?? 0
        return text.isEmpty ? [] : [.init(channel: channel, start: 0, end: duration, text: text)]
    }

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
