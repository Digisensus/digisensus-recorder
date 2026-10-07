import Foundation
import Testing
@testable import DigisensusRecorder

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct TranscriptionJobTests {
    private func client() -> TranscriptionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        var settings = TranscriptionSettings()
        settings.server = "https://recorder.example"
        settings.apiKey = "drk_test"
        return TranscriptionClient(settings: settings, session: URLSession(configuration: config))
    }

    private func answer(_ status: Int, _ json: String, headers: [String: String] = [:]) {
        MockURLProtocol.status = status
        MockURLProtocol.headers = headers
        MockURLProtocol.body = Data(json.utf8)
    }

    @Test func pollScheduleIsTenThenThirtyThenSixtySecondsForTwoHours() {
        #expect(TranscriptionClient.pollDelay(after: 0) == 10)
        #expect(TranscriptionClient.pollDelay(after: 99) == 10)
        #expect(TranscriptionClient.pollDelay(after: 100) == 30)
        #expect(TranscriptionClient.pollDelay(after: 199) == 30)
        #expect(TranscriptionClient.pollDelay(after: 200) == 60)
        #expect(TranscriptionClient.pollDelay(after: 249) == 60)
        #expect(TranscriptionClient.pollDelay(after: 250) == nil)
        let total = (0..<250).compactMap(TranscriptionClient.pollDelay(after:)).reduce(0, +)
        #expect(total == 7000)
    }

    @Test func pollReadsRunningDoneFailedAndThrottled() async throws {
        let client = client()
        answer(202, #"{"id":"j1","status":"running","poll_interval":10}"#)
        guard case .running(let hint) = try await client.poll("j1") else { Issue.record("not running"); return }
        #expect(hint == 10)

        answer(200, #"{"text":"labas","language":"lt","duration":90,"dialogue":[{"speaker":"agent","start":0,"end":90,"text":"labas"}]}"#)
        guard case .done(let json) = try await client.poll("j1") else { Issue.record("not done"); return }
        #expect(json["text"] as? String == "labas")
        let result = try await client.finish(json, file: URL(fileURLWithPath: "/dev/null")) { _ in
            Issue.record("the server labelled speakers: no channel split expected"); return [:]
        }
        #expect(result.turns.count == 1 && result.turns[0].channel == .me && result.language == "lt")

        answer(200, #"{"id":"j1","status":"failed","error":{"code":"transcription_failed","message":"Transcription failed. Please try again."}}"#)
        guard case .failed(let message) = try await client.poll("j1") else { Issue.record("not failed"); return }
        #expect(message == "Transcription failed. Please try again.")

        answer(429, #"{"error":{"code":"rate_limited","message":"Polling too often."}}"#, headers: ["Retry-After": "15"])
        guard case .running(let wait) = try await client.poll("j1") else { Issue.record("429 should mean keep waiting"); return }
        #expect(wait == 15)

        answer(404, #"{"error":{"code":"job_not_found","message":"No such transcription job."}}"#)
        guard case .failed = try await client.poll("j1") else { Issue.record("404 should fail the job"); return }

        answer(401, #"{"error":{"code":"invalid_api_key","message":"Not signed in."}}"#)
        await #expect(throws: TranscriptionError.self) { try await client.poll("j1") }

        let last = try #require(MockURLProtocol.requests.last)
        #expect(last.url?.path == "/v1/audio/transcriptions/jobs/j1")
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer drk_test")
    }

    @Test func submitPostsTheRecordingAndReadsTheJob() async throws {
        let client = client()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("job-\(UUID().uuidString).ogg")
        try Data("OggS".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        answer(202, #"{"id":"abc","status":"running","poll_interval":10,"audio_seconds":90}"#)
        let job = try await client.submit(file)
        #expect(job == TranscriptionClient.Job(id: "abc", pollInterval: 10))
        let request = try #require(MockURLProtocol.requests.last)
        #expect(request.httpMethod == "POST" && request.url?.path == "/v1/audio/transcriptions/jobs")

        answer(402, #"{"error":{"code":"insufficient_credits","message":"Today's free Digisensus credit is used up."}}"#)
        await #expect(throws: TranscriptionError.self) { try await client.submit(file) }
    }
}
