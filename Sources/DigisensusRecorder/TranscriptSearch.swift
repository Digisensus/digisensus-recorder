import Foundation

struct TranscriptMatch: Equatable {
    let segment: Int
    let range: Range<String.Index>
}

enum TranscriptSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func matches(of query: String, in segments: [TranscriptSegment]) -> [TranscriptMatch] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return segments.indices.flatMap { index in
            ranges(of: query, in: segments[index].text).map { TranscriptMatch(segment: index, range: $0) }
        }
    }

    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var rest = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: options, range: rest) {
            found.append(range)
            rest = range.upperBound..<text.endIndex
        }
        return found
    }

    static func spokenSegment(at time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].startTime <= time + 0.05 { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}
