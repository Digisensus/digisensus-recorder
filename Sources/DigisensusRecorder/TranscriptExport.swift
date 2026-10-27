import Foundation
import UniformTypeIdentifiers

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case text, markdown, srt, csv, json

    var id: String { rawValue }

    init?(name: String) {
        switch name.lowercased() {
        case "text", "txt", "plain": self = .text
        case "markdown", "md": self = .markdown
        case "srt", "subtitles": self = .srt
        case "csv": self = .csv
        case "json": self = .json
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .text: return "Plain Text"
        case .markdown: return "Markdown"
        case .srt: return "Subtitles (SRT)"
        case .csv: return "Spreadsheet (CSV)"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .csv: return "csv"
        case .json: return "json"
        }
    }

    var contentType: UTType {
        switch self {
        case .text: return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .srt: return UTType(filenameExtension: "srt") ?? .plainText
        case .csv: return .commaSeparatedText
        case .json: return .json
        }
    }
}

struct TranscriptExport {
    let recording: Recording
    let segments: [TranscriptSegment]
    var agreements: [Agreement] = []

    func render(_ format: TranscriptFormat) -> String {
        switch format {
        case .text: return text
        case .markdown: return markdown
        case .srt: return srt
        case .csv: return csv
        case .json: return json
        }
    }

    private var when: String {
        "\(recording.startedAt.formatted(date: .long, time: .shortened)) · \(recording.durationText)"
    }

    private static func speaker(_ segment: TranscriptSegment) -> String {
        segment.channel == .me ? "Me" : "Them"
    }

    private var text: String {
        var lines = [recording.heading, when, ""]
        lines += segments.map { "[\(RecorderModel.clock($0.startTime))] \(Self.speaker($0)): \($0.text)" }
        return lines.joined(separator: "\n") + "\n"
    }

    private var markdown: String {
        var lines = ["# \(recording.heading)", "", when, ""]
        if !recording.tags.isEmpty { lines += [String(localized: "Tags: \(recording.tags.joined(separator: ", "))"), ""] }
        if let summary = recording.summaryLong { lines += ["## " + String(localized: "Summary"), "", summary, ""] }
        if let points = recording.summaryPoints, !points.isEmpty { lines += points.map { "- \($0)" } + [""] }
        if let decisions = recording.summaryDecisions {
            lines += ["## " + String(localized: "Decisions"), ""] + decisions.map(\.markdown) + [""]
        }
        if let actions = recording.summaryActions {
            lines += ["## " + String(localized: "Action items"), ""] + actions.map(\.markdown) + [""]
        }
        if !agreements.isEmpty {
            lines += ["## " + String(localized: "Agreed in this call"), ""]
            lines += agreements.map { "- \($0.day)\($0.time.map { " \($0)" } ?? ""): \($0.title)" }
            lines.append("")
        }
        lines += ["## " + String(localized: "Transcript"), ""]
        lines += segments.map { "**\(Self.speaker($0))** [\(RecorderModel.clock($0.startTime))]: \($0.text)  " }
        return lines.joined(separator: "\n") + "\n"
    }

    private var srt: String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Self.srtClock(segment.startTime)) --> \(Self.srtClock(max(segment.endTime, segment.startTime + 0.5)))\n"
                + "\(Self.speaker(segment)): \(segment.text)\n"
        }.joined(separator: "\n")
    }

    private static func srtClock(_ time: Double) -> String {
        let milliseconds = Int((time * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }

    private var csv: String {
        let header = ["Time", "Speaker", "Text", "Start seconds", "End seconds"]
        let rows = segments.map { segment in
            [RecorderModel.clock(segment.startTime), Self.speaker(segment), segment.text,
             String(format: "%.2f", segment.startTime), String(format: "%.2f", segment.endTime)]
        }
        return "\u{FEFF}" + ([header] + rows).map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private var json: String {
        var object: [String: Any] = [
            "title": recording.heading,
            "started_at": ISO8601DateFormatter().string(from: recording.startedAt),
            "transcript": segments.map { ["speaker": $0.channel == .me ? "Me" : "Them", "start": $0.startTime, "end": $0.endTime, "text": $0.text] },
        ]
        object["duration_seconds"] = recording.duration
        object["language"] = recording.transcriptLanguage
        object["summary"] = recording.summaryLong
        object["points"] = recording.summaryPoints
        object["decisions"] = recording.summaryDecisions?.map(\.jsonObject)
        object["actions"] = recording.summaryActions?.map(\.jsonObject)
        if !recording.tags.isEmpty { object["tags"] = recording.tags }
        if !agreements.isEmpty { object["agreements"] = agreements.map(\.jsonObject) }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
