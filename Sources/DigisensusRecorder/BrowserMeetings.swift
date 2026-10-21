import AppKit

@MainActor
final class BrowserMeetings {
    enum Access { case allowed, denied, notAsked, unavailable }

    static let shared = BrowserMeetings()
    static let wantedKey = "meetingNamesWanted"
    static var isWanted: Bool { UserDefaults.standard.bool(forKey: wantedKey) }

    nonisolated static let scriptable = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
                                         "company.thebrowser.Browser", "com.apple.Safari"]

    private nonisolated static let meetings: [(host: String, label: String)] = [
        ("meet.google.com", "Meet"), ("zoom.us", "Zoom"), ("zoom.com", "Zoom"),
        ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"), ("teams.cloud.microsoft", "Teams"),
        ("whereby.com", "Whereby"), ("meet.jit.si", "Jitsi"), ("8x8.vc", "Jitsi"), ("webex.com", "Webex"),
        ("app.slack.com", "Slack"), ("discord.com", "Discord"),
    ]
    private static let retryInterval: TimeInterval = 10
    private static let keepInterval: TimeInterval = 300

    private var labels: [String: (label: String?, checked: Date)] = [:]
    private var checking: Set<String> = []

    func label(in bundleID: String) -> String? {
        guard Self.isWanted, Self.scriptable.contains(bundleID) else { return nil }
        let cached = labels[bundleID]
        let keep = cached?.label == nil ? Self.retryInterval : Self.keepInterval
        let stale = cached.map { Date().timeIntervalSince($0.checked) > keep } ?? true
        if stale, !checking.contains(bundleID) {
            checking.insert(bundleID)
            Task {
                let label = await Task.detached {
                    Self.access(to: bundleID, ask: false) == .allowed
                        ? Self.tabAddresses(in: bundleID).flatMap(Self.label(forTabs:)) : nil
                }.value
                labels[bundleID] = (label, Date())
                checking.remove(bundleID)
            }
        }
        return cached?.label
    }

    nonisolated static func askRunningBrowsers() -> Bool {
        runningBrowsers().map { access(to: $0, ask: true) }.contains(.denied)
    }

    nonisolated static func runningBrowsers() -> [String] {
        scriptable.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    nonisolated static func access(to bundleID: String, ask: Bool) -> Access {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return .unavailable }
        switch AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unavailable
        }
    }

    nonisolated static func label(forTabs addresses: [String]) -> String? {
        for address in addresses {
            guard let host = URL(string: address)?.host?.lowercased() else { continue }
            if let meeting = meetings.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }) {
                return meeting.label
            }
        }
        return nil
    }

    private nonisolated static func tabAddresses(in bundleID: String) -> [String]? {
        let source = """
            if application id "\(bundleID)" is running then
                with timeout of 2 seconds
                    tell application id "\(bundleID)" to return URL of every tab of every window
                end timeout
            end if
            """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if let error { Log.write("browser tabs of \(bundleID): \(error[NSAppleScript.errorNumber] ?? "?")") }
            return nil
        }
        return strings(in: result)
    }

    private nonisolated static func strings(in descriptor: NSAppleEventDescriptor) -> [String] {
        guard descriptor.descriptorType == typeAEList else { return descriptor.stringValue.map { [$0] } ?? [] }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).flatMap { descriptor.atIndex($0).map(strings) ?? [] }
    }
}
