import Foundation

enum UsageStatistics {
    static let sharingKey = "shareUsageStatistics"

    static var isShared: Bool {
        UserDefaults.standard.object(forKey: sharingKey) as? Bool ?? true
    }

    static func tag(_ request: inout URLRequest, launch: Bool) {
        AppVersion.tag(&request, withDevice: isShared)
        guard isShared else { return }
        if launch { request.setValue("1", forHTTPHeaderField: "X-App-Launch") }
        request.setValue(chip, forHTTPHeaderField: "X-App-Chip")
        if let language { request.setValue(language, forHTTPHeaderField: "X-App-Language") }
        let defaults = UserDefaults.standard
        let service = defaults.string(forKey: "aiService").flatMap(AIService.init(rawValue:)) ?? .digisensus
        request.setValue(service.rawValue, forHTTPHeaderField: "X-AI-Service")
        guard service == .own else { return }
        if let preset = knownPreset(defaults.string(forKey: "transcriptionPreset")) {
            request.setValue(preset, forHTTPHeaderField: "X-AI-Transcription")
        }
        if let preset = knownPreset(defaults.string(forKey: "summaryPreset")) {
            request.setValue(preset, forHTTPHeaderField: "X-AI-Summary")
        }
    }

    private static func knownPreset(_ id: String?) -> String? {
        id.flatMap(AIPreset.named)?.id
    }

    private static let chip: String = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isAppleSilicon = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        return isAppleSilicon ? "apple" : "intel"
    }()

    private static var language: String? {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
    }
}
