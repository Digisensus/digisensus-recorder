import AppKit
import CoreAudio
import Darwin

struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let isCapturing: Bool

    static func all() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            var pid: pid_t = 0
            guard read(object, kAudioProcessPropertyPID, into: &pid) else { return nil }
            var bundleID: CFString = "" as CFString
            _ = read(object, kAudioProcessPropertyBundleID, into: &bundleID)
            var capturing: UInt32 = 0
            _ = read(object, kAudioProcessPropertyIsRunningInput, into: &capturing)
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            return AudioProcess(object: object, pid: pid, bundleID: bundleID as String,
                                name: String(cString: name), isCapturing: capturing == 1)
        }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        } == noErr
    }
}

struct DetectedCall: Equatable {
    let label: String
    let source: AudioSource
}

enum CallDetector {
    private struct KnownApp {
        let prefix: String
        let label: String
        let appBundleID: String
        var isBrowser = false
    }

    private static let knownApps: [KnownApp] = [
        KnownApp(prefix: "us.zoom.xos", label: "Zoom", appBundleID: "us.zoom.xos"),
        KnownApp(prefix: "com.microsoft.teams", label: "Teams", appBundleID: "com.microsoft.teams2"),
        KnownApp(prefix: "com.tinyspeck.slackmacgap", label: "Slack", appBundleID: "com.tinyspeck.slackmacgap"),
        KnownApp(prefix: "net.whatsapp.WhatsApp", label: "WhatsApp", appBundleID: "net.whatsapp.WhatsApp"),
        KnownApp(prefix: "com.hnc.Discord", label: "Discord", appBundleID: "com.hnc.Discord"),
        KnownApp(prefix: "com.cisco.webexmeetingsapp", label: "Webex", appBundleID: "com.cisco.webexmeetingsapp"),
        KnownApp(prefix: "Cisco-Systems.Spark", label: "Webex", appBundleID: "Cisco-Systems.Spark"),
        KnownApp(prefix: "com.skype.skype", label: "Skype", appBundleID: "com.skype.skype"),
        KnownApp(prefix: "ru.keepcoder.Telegram", label: "Telegram", appBundleID: "ru.keepcoder.Telegram"),
        KnownApp(prefix: "org.whispersystems.signal-desktop", label: "Signal",
                 appBundleID: "org.whispersystems.signal-desktop"),
        KnownApp(prefix: "com.viber.osx", label: "Viber", appBundleID: "com.viber.osx"),
        KnownApp(prefix: "com.google.Chrome", label: "Chrome", appBundleID: "com.google.Chrome", isBrowser: true),
        KnownApp(prefix: "com.microsoft.edgemac", label: "Edge", appBundleID: "com.microsoft.edgemac", isBrowser: true),
        KnownApp(prefix: "com.brave.Browser", label: "Brave", appBundleID: "com.brave.Browser", isBrowser: true),
        KnownApp(prefix: "company.thebrowser.Browser", label: "Arc", appBundleID: "company.thebrowser.Browser",
                 isBrowser: true),
        KnownApp(prefix: "org.mozilla.firefox", label: "Firefox", appBundleID: "org.mozilla.firefox", isBrowser: true),
        KnownApp(prefix: "com.apple.WebKit.GPU", label: "Safari", appBundleID: "com.apple.Safari", isBrowser: true),
        KnownApp(prefix: "com.apple.Safari", label: "Safari", appBundleID: "com.apple.Safari", isBrowser: true),
    ]

    private static let webMeetings: [(keyword: String, label: String)] = [
        ("Meet", "Meet"), ("Zoom", "Zoom"), ("Microsoft Teams", "Teams"), ("Whereby", "Whereby"),
        ("Jitsi", "Jitsi"), ("Webex", "Webex"), ("Slack", "Slack"), ("Discord", "Discord"),
    ]

    private static let callDaemons: Set<String> = ["avconferenced", "callservicesd"]
    private static let callApps: Set<String> = ["com.apple.FaceTime", "com.apple.mobilephone"]

    static func currentCall() -> DetectedCall? {
        let own = ProcessInfo.processInfo.processIdentifier
        let capturing = AudioProcess.all().filter { $0.isCapturing && $0.pid != own }

        if let test = ProcessInfo.processInfo.environment["DSREC_DETECT_PROCESS"],
           capturing.contains(where: { $0.name == test }) {
            return DetectedCall(label: "Test", source: .calls)
        }

        if capturing.contains(where: { callDaemons.contains($0.name) || callApps.contains($0.bundleID) }) {
            let faceTimeIsOpen = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == "com.apple.FaceTime" }
            return DetectedCall(label: faceTimeIsOpen ? "FaceTime" : "Phone", source: .calls)
        }
        for process in capturing {
            guard let app = knownApps.first(where: { process.bundleID.hasPrefix($0.prefix) }) else { continue }
            let label = app.isBrowser ? webMeetingLabel(inWindowsOf: app.appBundleID) ?? app.label : app.label
            return DetectedCall(label: label, source: .application(bundleID: app.appBundleID))
        }
        return nil
    }

    private static func webMeetingLabel(inWindowsOf bundleID: String) -> String? {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }.map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[CFString: Any]]
        else { return nil }
        let titles = windows
            .filter { pids.contains(($0[kCGWindowOwnerPID] as? pid_t) ?? -1) }
            .compactMap { $0[kCGWindowName] as? String }
        return webMeetings.first { meeting in titles.contains { $0.contains(meeting.keyword) } }?.label
    }
}
