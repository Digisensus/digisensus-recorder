import Foundation

struct SummarySettings: Equatable {
    /// A chat server on this Mac, the usual first try.
    static let defaultServer = "http://localhost:9000"

    var provider = AIProvider.digisensus
    var server = SummarySettings.defaultServer
    var apiKey = ""
    var model = "qwen"
}

struct CallSummary: Equatable {
    /// One sentence, shown under the call in the archive list.
    var headline: String
    /// Up to five sentences, shown above the transcript.
    var summary: String
    /// A few words naming the subject: the call's heading.
    var topic: String? = nil
    /// Decisions, next steps and deadlines.
    var points: [String] = []
    /// Up to three labels for filtering the archive.
    var tags: [String] = []
}

enum SummaryError: LocalizedError {
    case badServerURL
    case server(Int, String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .badServerURL: return "The summary server address isn't a valid URL."
        case .server(let code, let detail) where AIProvider.explainsRefusal(status: code): return detail
        case .server(let code, let detail): return "The summary server answered \(code): \(detail)"
        case .emptyAnswer: return "The summary server returned no usable text."
        }
    }
}

/// Asks an OpenAI-compatible `/v1/chat/completions` endpoint to summarise a call transcript.
struct SummaryClient {
    let settings: SummarySettings

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

    /// Long enough for hours of talk, short enough to stay inside any large-context model.
    private static let transcriptCharacterLimit = 300_000

    /// `knownTags` are the tags already in the archive, offered for reuse so filters stay short.
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
        var body: [String: Any] = [
            "model": settings.model,
            "temperature": 0.2,
            "max_tokens": 900,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": "Transcript:\n\(transcript)"],
            ],
            // Reasoning models (Qwen, served by vLLM) otherwise spend the token budget thinking.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        let answer: String
        do {
            answer = try await complete(body)
        } catch SummaryError.server(let code, _) where code == 400 || code == 422 {
            // A stricter server rejected the vLLM-specific field; ask again without it.
            body["chat_template_kwargs"] = nil
            answer = try await complete(body)
        }
        return try Self.parse(answer)
    }

    func checkConnection() async -> String {
        guard let base = URL(string: settings.server) else { return "Not a valid URL." }
        var request = URLRequest(url: base.appendingPathComponent("v1/models"), timeoutInterval: 6)
        request.authorize(apiKey: settings.apiKey, provider: settings.provider)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return "No answer from \(settings.server)."
        }
        let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]]
        let names = models?.compactMap { $0["id"] as? String } ?? []
        if names.isEmpty { return "Connected." }
        return names.contains(settings.model)
            ? "Connected; model “\(settings.model)” is available."
            : "Connected, but it has no model “\(settings.model)”. It offers: \(names.joined(separator: ", "))."
    }

    // MARK: Request

    private func complete(_ body: [String: Any]) async throws -> String {
        guard let base = URL(string: settings.server), base.scheme != nil else { throw SummaryError.badServerURL }
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authorize(apiKey: settings.apiKey, provider: settings.provider)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            AppVersion.noteRefusal(status: status)
            throw SummaryError.server(status, detail)
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw SummaryError.emptyAnswer
        }
        return content
    }

    // MARK: Parsing

    /// Models wrap their JSON in reasoning blocks, code fences or chatter; dig it out, and
    /// fall back to reading plain prose as "first sentence, then the rest".
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
        return CallSummary(headline: firstSentence(of: prose), summary: prose)
    }

    private static func strings(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { $0 as? String }.map(clean).filter { !$0.isEmpty }
    }

    /// Case-insensitively unique, at most three, each at most a few words.
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
