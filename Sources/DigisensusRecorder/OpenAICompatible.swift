import Foundation

enum AIPurpose {
    case transcription, summary
}

struct AIPreset: Identifiable, Hashable {
    enum Place { case thisMac, cloud, anywhere }
    enum API { case openAICompatible, anthropic }

    let id: String
    let name: String
    let place: Place
    let server: String?
    let transcribes: Bool
    var api = API.openAICompatible
    var transcriptionModel: String? = nil
    var summaryModel: String? = nil

    static let local = AIPreset(id: "local", name: String(localized: "Local server"), place: .thisMac, server: nil, transcribes: true,
                                transcriptionModel: "whisper-1")
    static let other = AIPreset(id: "other", name: String(localized: "Other server"), place: .anywhere, server: nil, transcribes: true,
                                transcriptionModel: "whisper-1")

    static let all: [AIPreset] = [
        local,
        AIPreset(id: "ollama", name: "Ollama", place: .thisMac, server: "http://localhost:11434/v1", transcribes: false),
        AIPreset(id: "lmstudio", name: "LM Studio", place: .thisMac, server: "http://localhost:1234/v1", transcribes: false),
        AIPreset(id: "openai", name: "OpenAI", place: .cloud, server: "https://api.openai.com/v1", transcribes: true,
                 transcriptionModel: "whisper-1", summaryModel: "gpt-6-luna"),
        AIPreset(id: "anthropic", name: "Anthropic", place: .cloud, server: "https://api.anthropic.com/v1", transcribes: false,
                 api: .anthropic, summaryModel: "claude-haiku-5-5"),
        AIPreset(id: "gemini", name: "Google Gemini", place: .cloud,
                 server: "https://generativelanguage.googleapis.com/v1beta/openai", transcribes: false,
                 summaryModel: "gemini-flash-latest"),
        AIPreset(id: "mistral", name: "Mistral", place: .cloud, server: "https://api.mistral.ai/v1", transcribes: true,
                 transcriptionModel: "voxtral-mini-latest", summaryModel: "mistral-small-latest"),
        AIPreset(id: "groq", name: "Groq", place: .cloud, server: "https://api.groq.com/openai/v1", transcribes: true,
                 transcriptionModel: "whisper-large-v3-turbo"),
        AIPreset(id: "together", name: "Together AI", place: .cloud, server: "https://api.together.xyz/v1", transcribes: true,
                 transcriptionModel: "openai/whisper-large-v3"),
        AIPreset(id: "deepseek", name: "DeepSeek", place: .cloud, server: "https://api.deepseek.com/v1", transcribes: false,
                 summaryModel: "deepseek-chat"),
        AIPreset(id: "xai", name: "xAI", place: .cloud, server: "https://api.x.ai/v1", transcribes: false),
        AIPreset(id: "openrouter", name: "OpenRouter", place: .cloud, server: "https://openrouter.ai/api/v1", transcribes: false),
        other,
    ]

    static func named(_ id: String) -> AIPreset? {
        all.first { $0.id == id }
    }

    static func choices(for purposes: [AIPurpose], in place: Place) -> [AIPreset] {
        all.filter { $0.place == place && purposes.allSatisfy($0.serves) }
    }

    static func matching(server: String, for purpose: AIPurpose) -> AIPreset {
        let models = URL.endpoint("v1/models", on: server)
        if let models, let preset = all.first(where: {
            $0.serves(purpose) && $0.server.flatMap { URL.endpoint("v1/models", on: $0) } == models
        }) {
            return preset
        }
        let host = models?.host?.lowercased() ?? "localhost"
        return ["localhost", "127.0.0.1", "::1"].contains(host) ? local : other
    }

    func serves(_ purpose: AIPurpose) -> Bool {
        purpose == .summary || transcribes
    }

    func suggestedModel(for purpose: AIPurpose) -> String? {
        purpose == .transcription ? transcriptionModel : summaryModel
    }

    func defaultServer(for purpose: AIPurpose) -> String {
        if let server { return server }
        guard self == .local else { return "" }
        return purpose == .transcription ? TranscriptionSettings.defaultServer : SummarySettings.defaultServer
    }

    func addressPrompt(for purpose: AIPurpose) -> String {
        self == .local ? defaultServer(for: purpose) : "https://api.example.com/v1"
    }

    var keyPrompt: String {
        place == .cloud ? String(localized: "Required") : String(localized: "Optional")
    }
}

protocol AIServiceSettings: Sendable, SendableMetatype {
    var provider: AIProvider { get }
    var preset: String { get set }
    var server: String { get set }
    var apiKey: String { get set }
    var model: String { get set }
}

extension AIServiceSettings {
    func servicePreset(for purpose: AIPurpose) -> AIPreset {
        AIPreset.named(preset).flatMap { $0.serves(purpose) ? $0 : nil } ?? .matching(server: server, for: purpose)
    }

    func api(for purpose: AIPurpose) -> AIPreset.API {
        provider == .digisensus ? .openAICompatible : servicePreset(for: purpose).api
    }

    func sharesService(with other: some AIServiceSettings) -> Bool {
        preset == other.preset && AIPreset.named(preset)?.server != nil
    }

    mutating func use(_ preset: AIPreset, for purpose: AIPurpose, keyFrom other: some AIServiceSettings) {
        self.preset = preset.id
        server = preset.defaultServer(for: purpose)
        apiKey = sharesService(with: other) ? other.apiKey : ""
        model = preset.suggestedModel(for: purpose) ?? ""
    }
}

extension URLSession {
    static let app: URLSession = {
        let session = URLSession(configuration: .default, delegate: NoRedirects(), delegateQueue: nil)
        return session
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

extension URLRequest {
    private static let anthropicVersion = "2023-06-01"

    mutating func authorize(apiKey: String, provider: AIProvider, api: AIPreset.API) {
        guard api == .anthropic else { return authorize(apiKey: apiKey, provider: provider) }
        if !apiKey.isEmpty { setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
    }
}

extension URL {
    static func web(_ string: String) -> URL? {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func endpoint(_ path: String, on server: String) -> URL? {
        guard let base = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme != nil, base.host != nil else {
            return nil
        }
        let addressNamesAPIRoot = !base.path.isEmpty && base.path != "/"
        return base.appendingPathComponent(addressNamesAPIRoot && path.hasPrefix("v1/") ? String(path.dropFirst(3)) : path)
    }

    static func healthChecks(on server: String) -> [URL] {
        guard let underAPI = endpoint("health", on: server),
              var root = URLComponents(url: underAPI, resolvingAgainstBaseURL: false) else { return [] }
        root.path = "/health"
        return [root.url, underAPI].compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func sendsKeyInTheClear(_ settings: some AIServiceSettings) -> Bool {
        guard !settings.apiKey.isEmpty, let url = URL(string: settings.server.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return !["localhost", "127.0.0.1", "::1"].contains(host)
    }

    static func withoutCredentials(_ address: String) -> String {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.user != nil || parts.password != nil else { return address }
        parts.user = nil
        parts.password = nil
        return parts.string ?? address
    }

    static func apiRoot(fromLegacyAddress address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil,
              !url.path.isEmpty, url.path != "/", url.lastPathComponent != "v1" else { return address }
        return (trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed) + "/v1"
    }

    fileprivate var listingAll: URL {
        appending(queryItems: [URLQueryItem(name: "limit", value: "1000")])
    }
}

enum ModelList {
    private static let speechHints = ["whisper", "voxtral", "parakeet", "canary", "asr", "stt"]
    private static let notForChat = ["whisper", "transcribe", "tts", "embed", "dall-e", "image", "moderation", "realtime",
                                     "audio", "sora", "rerank", "voxtral", "parakeet", "babbage", "davinci", "ocr",
                                     "bge-", "minilm", "guard", "search", "vision"]
    private static let chatHints = ["instruct", "chat"]

    static func fetch(_ settings: some AIServiceSettings, for purpose: AIPurpose,
                      session: URLSession = .app) async -> (status: Int?, names: [String]) {
        let api = settings.api(for: purpose)
        guard let url = URL.endpoint("v1/models", on: settings.server).map({ api == .anthropic ? $0.listingAll : $0 }) else {
            return (nil, [])
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.authorize(apiKey: settings.apiKey, provider: settings.provider, api: api)
        guard let (data, response) = try? await session.data(for: request) else { return (nil, []) }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { return (status, []) }
        let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]]
        let names = models?.compactMap { $0["id"] as? String }.map(withoutResourcePrefix) ?? []
        return (status, names)
    }

    static func offered(_ names: [String], for purpose: AIPurpose) -> [String] {
        let fitting = names.filter { name in
            let id = name.lowercased()
            switch purpose {
            case .transcription: return speechHints.contains { id.contains($0) }
            case .summary: return !notForChat.contains { id.contains($0) }
            }
        }
        return Array(Set(fitting.isEmpty ? names : fitting)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func likelyChatModel(in names: [String]) -> String? {
        let fitting = names.filter { name in !notForChat.contains { name.lowercased().contains($0) } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return fitting.first { name in chatHints.contains { name.lowercased().contains($0) } } ?? fitting.first
    }

    private static func withoutResourcePrefix(_ name: String) -> String {
        name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
    }
}

enum ConnectionCheck {
    private static let offeredModelLimit = 12

    static func run(_ settings: some AIServiceSettings, for purpose: AIPurpose, session: URLSession = .app) async -> String {
        let healthChecks = URL.healthChecks(on: settings.server)
        guard !healthChecks.isEmpty else { return String(localized: "Not a valid URL.") }
        let warning = URL.sendsKeyInTheClear(settings) ? " " + String(localized: "Warning: this address is http, so the API key travels unencrypted.") : ""
        let listed = await ModelList.fetch(settings, for: purpose, session: session)
        if listed.status == 200 {
            return (settings.provider == .digisensus ? String(localized: "Connected.") : describe(listed.names, model: settings.model, for: purpose))
                + warning
        }
        if listed.status == 401 || listed.status == 403 { return failure(settings.server, status: listed.status) }
        var healthStatus: Int?
        for health in healthChecks {
            var request = URLRequest(url: health, timeoutInterval: 6)
            request.authorize(apiKey: settings.apiKey, provider: settings.provider, api: settings.api(for: purpose))
            let status = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            if status == 200 { return String(localized: "Connected.") + warning }
            healthStatus = healthStatus ?? status
        }
        return failure(settings.server, status: listed.status ?? healthStatus)
    }

    static func describe(_ names: [String], model: String, for purpose: AIPurpose) -> String {
        guard !model.isEmpty else { return String(localized: "Connected, but no model is chosen. Choose one in Settings › Transcription & AI.") }
        guard !names.isEmpty else { return String(localized: "Connected.") }
        if names.contains(model) { return String(localized: "Connected; model “\(model)” is available.") }
        let offered = ModelList.offered(names, for: purpose)
        let shown = offered.prefix(offeredModelLimit).joined(separator: ", ") + (offered.count > offeredModelLimit ? ", …" : "")
        return String(localized: "Connected, but it has no model “\(model)”. It offers: \(shown).")
    }

    static func failure(_ server: String, status: Int?) -> String {
        switch status {
        case nil: return String(localized: "No answer from \(server).")
        case 401, 403: return String(localized: "\(server) refused the API key.")
        case let status?: return String(localized: "\(server) answered \(status). Check the server address.")
        }
    }
}
