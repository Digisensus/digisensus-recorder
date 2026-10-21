import Testing
@testable import DigisensusRecorder

struct BrowserMeetingTests {
    @Test func meetingTabsAreNamedByTheirService() {
        #expect(BrowserMeetings.label(forTabs: ["https://mail.google.com/", "https://meet.google.com/abc-defg-hij"]) == "Meet")
        #expect(BrowserMeetings.label(forTabs: ["https://us02web.zoom.us/wc/123456/join"]) == "Zoom")
        #expect(BrowserMeetings.label(forTabs: ["https://teams.microsoft.com/v2/"]) == "Teams")
        #expect(BrowserMeetings.label(forTabs: ["https://meet.jit.si/standup"]) == "Jitsi")
    }

    @Test func otherTabsGiveNoName() {
        #expect(BrowserMeetings.label(forTabs: ["https://www.youtube.com/watch?v=1", "about:blank", ""]) == nil)
        #expect(BrowserMeetings.label(forTabs: ["https://notzoom.us.example.com/"]) == nil)
    }
}
