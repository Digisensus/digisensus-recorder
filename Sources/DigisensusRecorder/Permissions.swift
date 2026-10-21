import AppKit
import AVFoundation
import UserNotifications

@MainActor
final class Permissions: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, systemAudio, notifications, meetingNames
        var id: String { rawValue }

        var name: String {
            switch self {
            case .microphone: return "Microphone"
            case .systemAudio: return "System audio"
            case .notifications: return "Notifications"
            case .meetingNames: return "Meeting names"
            }
        }

        var isRequired: Bool { self == .microphone || self == .systemAudio }

        fileprivate var settingsPane: String {
            switch self {
            case .microphone: return "Privacy_Microphone"
            case .systemAudio: return "Privacy_ScreenCapture"
            case .notifications: return ""
            case .meetingNames: return "Privacy_Automation"
            }
        }
    }

    @Published private(set) var microphone = false
    @Published private(set) var systemAudio = false
    @Published private(set) var notifications = false
    @Published private(set) var systemAudioRefused = false
    @Published private(set) var meetingNames = false
    @Published private(set) var meetingNamesRefused = false

    static let systemAudioHint = "Already on in System Settings? It may belong to another copy of Digisensus Recorder. "
        + "Select Digisensus Recorder there, remove it with the − button, then allow it again."

    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?
    private var pollTicks = 0

    init() {
        refresh()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                if SystemAudioAccess.wasRequested { self?.checkSystemAudio() }
                self?.askBrowsersIfWanted()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: SystemAudioAccess.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        if SystemAudioAccess.wasRequested { checkSystemAudio() }
    }

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone: return microphone
        case .systemAudio: return systemAudio
        case .notifications: return notifications
        case .meetingNames: return meetingNames
        }
    }

    var missing: [Kind] { Kind.allCases.filter { !isGranted($0) } }
    var requiredGranted: Bool { microphone && systemAudio }

    private static let demo = ProcessInfo.processInfo.environment["DSREC_DEMO"] != nil

    func refresh() {
        if Self.demo {
            (microphone, systemAudio, notifications, meetingNames) = (true, true, true, true)
            return
        }
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudio = SystemAudioAccess.lastKnown == .granted
        let refused = SystemAudioAccess.wasRequested && SystemAudioAccess.lastKnown == .denied
        if refused != systemAudioRefused { systemAudioRefused = refused }
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notifications = status == .authorized || status == .provisional
        }
        Task {
            let refused = await Task.detached { Self.browserRefused() }.value
            if refused != meetingNamesRefused { meetingNamesRefused = refused }
            let granted = BrowserMeetings.isWanted && !refused
            if granted != meetingNames { meetingNames = granted }
        }
    }

    private nonisolated static func browserRefused() -> Bool {
        BrowserMeetings.runningBrowsers().contains { BrowserMeetings.access(to: $0, ask: false) == .denied }
    }

    func startWatching() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.pollTicks += 1
                if self.pollTicks % 10 == 0 { self.recheckSystemAudio() }
            }
        }
        poll?.tolerance = 0.2
    }

    private func askBrowsersIfWanted() {
        guard BrowserMeetings.isWanted else { return }
        Task {
            let unanswered = await Task.detached {
                BrowserMeetings.runningBrowsers().contains { BrowserMeetings.access(to: $0, ask: false) == .notAsked }
            }.value
            guard unanswered else { return }
            _ = await Task.detached { BrowserMeetings.askRunningBrowsers() }.value
            refresh()
        }
    }

    private func recheckSystemAudio() {
        guard SystemAudioAccess.wasRequested, !systemAudio else { return }
        checkSystemAudio()
    }

    private func checkSystemAudio() {
        Task { _ = await SystemAudioAccess.check() }
    }

    func stopWatching() {
        poll?.invalidate()
        poll = nil
    }

    func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    refresh()
                }
            } else {
                openSettings(for: kind)
            }
        case .systemAudio:
            let askedBefore = SystemAudioAccess.wasRequested
            Task {
                if await SystemAudioAccess.check() == .denied, askedBefore { openSettings(for: kind) }
                refresh()
            }
        case .notifications:
            Task {
                let center = UNUserNotificationCenter.current()
                if await center.notificationSettings().authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                } else {
                    openSettings(for: kind)
                }
                refresh()
            }
        case .meetingNames:
            UserDefaults.standard.set(true, forKey: BrowserMeetings.wantedKey)
            Task {
                let refused = await Task.detached { BrowserMeetings.askRunningBrowsers() }.value
                if refused { openSettings(for: kind) }
                refresh()
            }
        }
    }

    func openSettings(for kind: Kind) {
        let url = kind == .notifications
            ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
            : "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
