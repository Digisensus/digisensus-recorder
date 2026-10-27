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
        if let model { request.setValue(model, forHTTPHeaderField: "X-App-Model") }
        if let chip { request.setValue(chip, forHTTPHeaderField: "X-App-Chip") }
        if let language { request.setValue(language, forHTTPHeaderField: "X-App-Language") }
        request.setValue(AppLanguage.inUse, forHTTPHeaderField: "X-App-UI-Language")
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

    private static let model = systemValue("hw.model")
    private static let chip = systemValue("machdep.cpu.brand_string")

    private static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: bytes).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static var language: String? {
        AppLanguage.systemLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
    }
}
