import Foundation
import Testing
@testable import DigisensusRecorder

@Suite(.serialized)
struct UsageStatisticsTests {
    private let keys = [UsageStatistics.sharingKey, "aiService", "transcriptionPreset", "summaryPreset"]

    private func tagged(launch: Bool, settings: [String: Any]) -> URLRequest {
        let defaults = UserDefaults.standard
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        var request = URLRequest(url: URL(string: "https://recorder.example/v1/messages")!)
        UsageStatistics.tag(&request, launch: launch)
        return request
    }

    @Test func sharedByDefault() {
        let request = tagged(launch: true, settings: [:])
        #expect(request.value(forHTTPHeaderField: "X-App-Build") == AppVersion.build)
        #expect(request.value(forHTTPHeaderField: "X-App-Distribution") == AppDistribution.current.rawValue)
        #expect(request.value(forHTTPHeaderField: "X-Device-ID") == AppVersion.deviceID)
        #expect(request.value(forHTTPHeaderField: "X-App-Launch") == "1")
        #expect(request.value(forHTTPHeaderField: "X-App-Chip")?.hasPrefix("Apple M") == true)
        #expect(request.value(forHTTPHeaderField: "X-App-Model")?.contains(",") == true)
        #expect(request.value(forHTTPHeaderField: "X-App-UI-Language") == AppLanguage.inUse)
        #expect(request.value(forHTTPHeaderField: "X-AI-Service") == "digisensus")
        #expect(request.value(forHTTPHeaderField: "X-AI-Transcription") == nil)
    }

    @Test func ownServiceNamesOnlyKnownPresets() {
        let request = tagged(launch: false, settings: [
            "aiService": "own", "transcriptionPreset": "local", "summaryPreset": "https://example.com/v1",
        ])
        #expect(request.value(forHTTPHeaderField: "X-App-Launch") == nil)
        #expect(request.value(forHTTPHeaderField: "X-AI-Service") == "own")
        #expect(request.value(forHTTPHeaderField: "X-AI-Transcription") == "local")
        #expect(request.value(forHTTPHeaderField: "X-AI-Summary") == nil)
    }

    @Test func turnedOffSendsOnlyTheVersion() {
        let request = tagged(launch: true, settings: [UsageStatistics.sharingKey: false, "aiService": "own"])
        #expect(request.value(forHTTPHeaderField: "X-App-Build") == AppVersion.build)
        #expect(request.value(forHTTPHeaderField: "X-App-Distribution") != nil)
        for header in ["X-Device-ID", "X-App-Launch", "X-App-Model", "X-App-Chip", "X-App-Language", "X-App-UI-Language",
                       "X-AI-Service"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
    }
}
