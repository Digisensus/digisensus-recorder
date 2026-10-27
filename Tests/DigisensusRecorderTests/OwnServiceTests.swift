import Foundation
import Testing
@testable import DigisensusRecorder

final class OwnServiceURLProtocol: URLProtocol {
    nonisolated(unsafe) static var answers: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [(url: URL, body: Data, headers: [String: String])] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append((request.url!, Self.body(of: request), request.allHTTPHeaderFields ?? [:]))
        let answer = Self.answers.isEmpty ? (status: 500, body: "") : Self.answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { data.append(buffer, count: count) }
        return data
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OwnServiceURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct OwnServiceTests {
    private let transcript = [TranscriptSegment(id: nil, recordingId: 1, channel: .me, startTime: 0, endTime: 2, text: "Labas")]
    private let summaryAnswer = #"{"choices":[{"message":{"content":"{\"headline\":\"Short call.\",\"summary\":\"Short call.\"}"}}]}"#

    private func summaryClient(preset: AIPreset, server: String, apiKey: String = "") -> SummaryClient {
        var settings = SummarySettings()
        settings.apiKey = apiKey
        settings.provider = .custom
        settings.preset = preset.id
        settings.server = server
        settings.model = "gpt-6-luna"
        return SummaryClient(settings: settings, session: OwnServiceURLProtocol.session)
    }

    private func sentBodies() -> [[String: Any]] {
        OwnServiceURLProtocol.requests.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
    }

    @Test func cloudSummaryRetriesWithoutTuningWhenTheModelRefusesIt() async throws {
        OwnServiceURLProtocol.requests = []
        OwnServiceURLProtocol.answers = [
            (400, #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model."}}"#),
            (200, summaryAnswer),
        ]
        let summary = try await summaryClient(preset: AIPreset.named("openai")!, server: "https://api.openai.com/v1")
            .summarize(transcript)
        #expect(summary.headline == "Short call.")
        let bodies = sentBodies()
        #expect(bodies.count == 2)
        #expect(bodies[0]["max_tokens"] as? Int == 3000 && bodies[0]["chat_template_kwargs"] == nil)
        #expect(bodies[1]["max_tokens"] == nil && bodies[1]["temperature"] == nil)
        #expect(OwnServiceURLProtocol.requests.map(\.url.absoluteString).allSatisfy {
            $0 == "https://api.openai.com/v1/chat/completions"
        })
    }

    @Test func localSummaryFirstAsksToSkipThinking() async throws {
        OwnServiceURLProtocol.requests = []
        OwnServiceURLProtocol.answers = [(400, "{}"), (400, "{}"), (400, #"{"error":{"message":"bad request"}}"#)]
        await #expect(throws: SummaryError.self) {
            try await summaryClient(preset: .local, server: "http://localhost:9000").summarize(transcript)
        }
        let bodies = sentBodies()
        #expect(bodies.count == 3)
        #expect(bodies[0]["chat_template_kwargs"] != nil)
        #expect(bodies[1]["chat_template_kwargs"] == nil && bodies[1]["max_tokens"] as? Int == 3000)
        #expect(bodies[2]["max_tokens"] == nil)
    }

    @Test func anthropicSummaryUsesTheMessagesAPI() async throws {
        OwnServiceURLProtocol.requests = []
        OwnServiceURLProtocol.answers = [(200, #"""
            {"type":"message","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},
            {"type":"text","text":"{\"headline\":\"Short call.\",\"summary\":\"Short call.\"}"}]}
            """#)]
        let summary = try await summaryClient(preset: AIPreset.named("anthropic")!, server: "https://api.anthropic.com/v1",
                                              apiKey: "sk-test").summarize(transcript)

        #expect(summary.headline == "Short call.")
        let request = try #require(OwnServiceURLProtocol.requests.first)
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.headers["x-api-key"] == "sk-test")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(request.headers["Authorization"] == nil)
        let body = try #require(sentBodies().first)
        #expect(body["system"] is String)
        #expect((body["messages"] as? [[String: Any]])?.map { $0["role"] as? String } == ["user"])
        #expect(body["max_tokens"] as? Int == 16000 && body["temperature"] == nil)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func anthropicSummaryRetriesWithoutEffortForOlderModels() async throws {
        OwnServiceURLProtocol.requests = []
        OwnServiceURLProtocol.answers = [
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"effort is not supported"}}"#),
            (200, #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"headline\":\"Short call.\"}"}]}"#),
        ]
        let summary = try await summaryClient(preset: AIPreset.named("anthropic")!, server: "https://api.anthropic.com/v1")
            .summarize(transcript)
        #expect(summary.headline == "Short call.")
        #expect(sentBodies().map { $0["output_config"] == nil } == [false, true])
    }

    @Test func anthropicRefusalIsReportedAsDeclined() async throws {
        OwnServiceURLProtocol.requests = []
        OwnServiceURLProtocol.answers = [(200, #"{"stop_reason":"refusal","content":[]}"#)]
        await #expect(throws: SummaryError.self) {
            try await summaryClient(preset: AIPreset.named("anthropic")!, server: "https://api.anthropic.com/v1")
                .summarize(transcript)
        }
        #expect(OwnServiceURLProtocol.requests.count == 1)
    }

    @Test func anthropicModelListAsksForAllModelsWithItsOwnHeaders() async throws {
        var settings = SummarySettings()
        settings.provider = .custom
        settings.preset = "anthropic"
        settings.server = "https://api.anthropic.com/v1"
        settings.apiKey = "sk-test"
        OwnServiceURLProtocol.requests = []
        OwnServiceURLProtocol.answers = [(200, #"{"data":[{"id":"claude-haiku-5-5","type":"model"}],"has_more":false}"#)]
        let listed = await ModelList.fetch(settings, for: .summary, session: OwnServiceURLProtocol.session)

        #expect(listed.names == ["claude-haiku-5-5"])
        let request = try #require(OwnServiceURLProtocol.requests.first)
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(request.headers["x-api-key"] == "sk-test" && request.headers["Authorization"] == nil)
    }

    @Test func anthropicPresetIsIgnoredWhileSignedInToDigisensus() {
        var settings = SummarySettings()
        settings.preset = "anthropic"
        #expect(settings.api(for: .summary) == .openAICompatible)
        settings.provider = .custom
        #expect(settings.api(for: .summary) == .anthropic)
    }

    @Test func ownServerTranscribesEachChannelWithoutTheAgentChannelField() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("own-\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: file) }
        let encoder = try OggOpusEncoder(url: file, channels: 2, bitrate: RecordingFile.opusBitrate)
        try [Float](repeating: 0, count: 48_000 * 2).withUnsafeBufferPointer { try encoder.append($0) }
        try encoder.finish()

        var settings = TranscriptionSettings()
        settings.provider = .custom
        settings.preset = "openai"
        settings.server = "https://api.openai.com/v1"
        OwnServiceURLProtocol.requests = []
        OwnServiceURLProtocol.answers = [
            (200, #"{"text":"Hello","language":"english","duration":1,"segments":[{"start":0,"end":1,"text":"Hello"}]}"#),
            (200, #"{"text":"Labas","language":"lithuanian","duration":1,"segments":[{"start":0.5,"end":1,"text":"Labas"}]}"#),
        ]
        let result = try await TranscriptionClient(settings: settings, session: OwnServiceURLProtocol.session).transcribe(file)

        #expect(OwnServiceURLProtocol.requests.count == 2, "one request per channel, no stereo request first")
        for request in OwnServiceURLProtocol.requests {
            #expect(request.url.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
            #expect(!String(decoding: request.body.prefix(4096), as: UTF8.self).contains("agent_channel"))
        }
        #expect(result.turns.map(\.channel) == [.them, .me])
        #expect(result.language == "english")
    }
}
