import Foundation

struct Speaker: Codable, Equatable {
    var number: Int
    var name: String?
    var namedByYou: Bool

    static func found(in segments: [TranscriptSegment]) -> [Speaker]? {
        let numbers = Set(segments.filter { $0.channel == .them }.compactMap(\.speaker))
        return numbers.isEmpty ? nil : numbers.sorted().map { Speaker(number: $0, name: nil, namedByYou: false) }
    }

    static func cleanName(_ name: String) -> String? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return name.isEmpty ? nil : name
    }
}

extension Recording {
    func speaker(of segment: TranscriptSegment) -> Speaker? {
        guard segment.channel == .them, let number = segment.speaker else { return nil }
        return speakers?.first { $0.number == number }
    }

    func speakerLabel(_ segment: TranscriptSegment, localized: Bool) -> String? {
        guard let speaker = speaker(of: segment) else { return nil }
        if let name = speaker.name { return name }
        guard let speakers, speakers.count > 1 else { return nil }
        return localized ? String(localized: "Speaker \(speaker.number + 1)") : "Speaker \(speaker.number + 1)"
    }

    func exportLabel(_ segment: TranscriptSegment, localized: Bool) -> String {
        if let label = speakerLabel(segment, localized: localized) { return label }
        switch (segment.channel, localized) {
        case (.me, true): return String(localized: "Me")
        case (.me, false): return "Me"
        case (.them, true): return String(localized: "Them")
        case (.them, false): return "Them"
        }
    }

    func speakerNumber(forLabel label: String) -> Int? {
        guard let speakers else { return nil }
        let label = label.trimmingCharacters(in: .whitespaces).lowercased()
        if label == "them" { return speakers.count == 1 ? speakers[0].number : nil }
        guard label.hasPrefix("speaker "), let shown = Int(label.dropFirst("speaker ".count)) else { return nil }
        return speakers.contains { $0.number == shown - 1 } ? shown - 1 : nil
    }
}
