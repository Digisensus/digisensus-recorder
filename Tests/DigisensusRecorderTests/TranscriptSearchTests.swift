import Foundation
import Testing
@testable import DigisensusRecorder

struct TranscriptSearchTests {
    private let segments = [
        TranscriptSegment(recordingId: 1, channel: .me, startTime: 0, endTime: 2, text: "Sveiki, čia Jonas."),
        TranscriptSegment(recordingId: 1, channel: .them, startTime: 2.5, endTime: 5, text: "Labas, Jonai. Cia Ona."),
        TranscriptSegment(recordingId: 1, channel: .me, startTime: 6, endTime: 8, text: "Price is fine, the PRICE list too."),
    ]

    @Test func findsEveryOccurrenceIgnoringCaseAndAccents() {
        let matches = TranscriptSearch.matches(of: " cia ", in: segments)
        #expect(matches.map(\.segment) == [0, 1])
        #expect(matches.map { String(segments[$0.segment].text[$0.range]) } == ["čia", "Cia"])
        #expect(TranscriptSearch.matches(of: "price", in: segments).map(\.segment) == [2, 2])
    }

    @Test func emptyQueryFindsNothing() {
        #expect(TranscriptSearch.matches(of: "  ", in: segments).isEmpty)
        #expect(TranscriptSearch.matches(of: "budget", in: segments).isEmpty)
    }

    @Test func playbackFollowsTheLineThatStartedLast() {
        #expect(TranscriptSearch.spokenSegment(at: 0, in: segments) == 0)
        #expect(TranscriptSearch.spokenSegment(at: 2.2, in: segments) == 0)
        #expect(TranscriptSearch.spokenSegment(at: 2.5, in: segments) == 1)
        #expect(TranscriptSearch.spokenSegment(at: 100, in: segments) == 2)
        #expect(TranscriptSearch.spokenSegment(at: 1, in: []) == nil)
    }
}
