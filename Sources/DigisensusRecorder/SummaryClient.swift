import Foundation

struct SummarySettings: Equatable, AIServiceSettings {
    static let defaultServer = "http://localhost:9000/v1"

    var provider = AIProvider.digisensus
    var preset = AIPreset.local.id
    var server = SummarySettings.defaultServer
    var apiKey = ""
    var model = "qwen"
}

struct CallSummary: Equatable {
    var headline: String
    var summary: String
    var topic: String? = nil
    var points: [String] = []
    var tags: [String] = []
}

enum SummaryError: LocalizedError {
    case badServerURL
    case server(Int, String)
    case emptyAnswer
    case cutOff
    case declined

    var errorDescription: String? {
        switch self {
        case .badServerURL: return "The summary server address isn't a valid URL."
        case .server(let code, let detail) where AIProvider.explainsRefusal(status: code): return detail
        case .server(let code, let detail): return "The summary server answered \(code): \(detail)"
        case .emptyAnswer: return "The summary server returned no usable text."
        case .cutOff: return "The summary model stopped before finishing its answer."
        case .declined: return "The model declined to summarise this call."
        }
    }
}

struct SummaryClient {
    let settings: SummarySettings
    var session: URLSession = .app

    private static let instructions = """
        You summarise recorded phone calls and meetings from their transcripts. The transcript labels \
        the person who made the recording as "Me" and the other side as "Them". It comes from speech \
        recognition, so expect misheard or duplicated words and read through them.

        Answer with one JSON object and nothing else:
        {"topic": "...", "headline": "...", "summary": "...", "points": ["..."], "tags": ["..."]}
        - "topic": 2 to 5 words naming the subject, like a title, with no final period.
        - "headline": exactly one sentence, at most 20 words, saying what the call was about.
        - "summary": at most 3 sentences covering the topic and what was decided.
        - "points": up to 4 short bullet points with decisions, next steps and deadlines. Start a \
        step with "You:" when the person who recorded has to act, "Them:" when the other side does. \
        Use an empty list when there are none.
        - "tags": 1 to 3 short tags (one or two words, capitalised) that sort the call, such as \
        Work, Clients, Hiring or Personal.
        Write everything in the language the transcript is mostly in. Use only what the transcript \
        says; if there is too little to summarise, say so in one short sentence and leave the lists empty.
        """

    private static let transcriptCharacterLimit = 300_000

    func summarize(_ segments: [TranscriptSegment], knownTags: [String] = []) async throws -> CallSummary {
        var transcript = segments.map { segment in
            let seconds = Int(segment.startTime)
            let speaker = segment.channel == .me ? "Me" : "Them"
            return String(format: "[%d:%02d] %@: %@", seconds / 60, seconds % 60, speaker, segment.text)
        }.joined(separator: "\n")
        if transcript.count > Self.transcriptCharacterLimit {
            transcript = String(transcript.prefix(Self.transcriptCharacterLimit)) + "\n[transcript cut off here]"
        }

        var instructions = Self.instructions
        if !knownTags.isEmpty {
            instructions += "\nTags already in use (reuse one when it fits): \(knownTags.prefix(40).joined(separator: ", "))."
        }
        let attempts = api == .anthropic
            ? Self.messagesAttempts(model: settings.model, instructions: instructions, transcript: transcript)
            : chatCompletionAttempts(instructions: instructions, transcript: transcript)
        for (index, body) in attempts.enumerated() {
            let isLast = index == attempts.count - 1
            do {
                return try Self.parse(try await complete(body))
            } catch SummaryError.server(let code, _) where (code == 400 || code == 422) && !isLast {
                continue
            } catch SummaryError.cutOff where !isLast {
                continue
            }
        }
        throw SummaryError.emptyAnswer
    }

    private var api: AIPreset.API { settings.api(for: .summary) }

    private func chatCompletionAttempts(instructions: String, transcript: String) -> [[String: Any]] {
        let plain: [String: Any] = [
            "model": settings.model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": "Transcript:\n\(transcript)"],
            ],
        ]
        let tuned = plain.merging(["temperature": 0.2, "max_tokens": 900]) { $1 }
        var attempts = [tuned, plain]
        if sendsChatTemplateHints {
            attempts.insert(tuned.merging(["chat_template_kwargs": ["enable_thinking": false]]) { $1 }, at: 0)
        }
        return attempts
    }

    private static func messagesAttempts(model: String, instructions: String, transcript: String) -> [[String: Any]] {
        let plain: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": instructions,
            "messages": [["role": "user", "content": "Transcript:\n\(transcript)"]],
        ]
        return [plain.merging(["output_config": ["effort": "low"]]) { $1 }, plain]
    }

    private var sendsChatTemplateHints: Bool {
        settings.provider == .digisensus || settings.servicePreset(for: .summary).place != .cloud
    }

    func checkConnection() async -> String {
        await ConnectionCheck.run(settings, for: .summary, session: session)
    }

    private func complete(_ body: [String: Any]) async throws -> String {
        let path = api == .anthropic ? "v1/messages" : "v1/chat/completions"
        guard let url = URL.endpoint(path, on: settings.server) else { throw SummaryError.badServerURL }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authorize(apiKey: settings.apiKey, provider: settings.provider, api: api)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            AppVersion.noteRefusal(status: status)
            throw SummaryError.server(status, detail)
        }
        if Self.wasCutOff(json) { throw SummaryError.cutOff }
        let content = api == .anthropic ? try Self.messagesText(json) : Self.chatCompletionText(json)
        guard let content, !content.isEmpty else { throw SummaryError.emptyAnswer }
        return content
    }

    private static func wasCutOff(_ json: [String: Any]?) -> Bool {
        let choice = (json?["choices"] as? [[String: Any]])?.first
        return choice?["finish_reason"] as? String == "length" || json?["stop_reason"] as? String == "max_tokens"
    }

    private static func chatCompletionText(_ json: [String: Any]?) -> String? {
        let choices = json?["choices"] as? [[String: Any]]
        return (choices?.first?["message"] as? [String: Any])?["content"] as? String
    }

    private static func messagesText(_ json: [String: Any]?) throws -> String? {
        if json?["stop_reason"] as? String == "refusal" { throw SummaryError.declined }
        let blocks = json?["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    static func parse(_ answer: String) throws -> CallSummary {
        var text = answer
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let open = text.range(of: "<think>") { text.removeSubrange(open.lowerBound..<text.endIndex) }

        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] {
            let headline = clean(object["headline"] as? String ?? "")
            let summary = clean(object["summary"] as? String ?? "")
            if !headline.isEmpty || !summary.isEmpty {
                let topic = clean(object["topic"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return CallSummary(headline: headline.isEmpty ? firstSentence(of: summary) : headline,
                                   summary: summary.isEmpty ? headline : summary,
                                   topic: topic.isEmpty ? nil : topic,
                                   points: strings(object["points"]),
                                   tags: uniqueTags(strings(object["tags"])))
            }
        }

        let prose = clean(text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: ""))
        guard !prose.isEmpty else { throw SummaryError.emptyAnswer }
        guard !prose.hasPrefix("{") else { throw SummaryError.cutOff }
        return CallSummary(headline: firstSentence(of: prose), summary: prose)
    }

    private static func strings(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { $0 as? String }.map(clean).filter { !$0.isEmpty }
    }

    private static func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { String($0.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstSentence(of text: String) -> String {
        var sentence = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, stop in
            sentence = clean(substring ?? "")
            stop = true
        }
        return sentence.isEmpty ? text : sentence
    }
}
