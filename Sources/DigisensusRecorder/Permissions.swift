import AppKit
import AVFoundation
import UserNotifications

/// The three permissions the app asks for, kept current while the user flips them in
/// System Settings.
@MainActor
final class Permissions: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, systemAudio, notifications
        var id: String { rawValue }

        var name: String {
            switch self {
            case .microphone: return "Microphone"
            case .systemAudio: return "System audio"
            case .notifications: return "Notifications"
            }
        }

        /// Recording needs these; notifications are only recommended.
        var isRequired: Bool { self != .notifications }

        fileprivate var settingsPane: String {
            switch self {
            case .microphone: return "Privacy_Microphone"
            case .systemAudio: return "Privacy_ScreenCapture"
            case .notifications: return "Notifications"
            }
        }
    }

    @Published private(set) var microphone = false
    @Published private(set) var systemAudio = false
    @Published private(set) var notifications = false
    /// System audio was asked for already and is still refused (see `systemAudioHint`).
    @Published private(set) var systemAudioRefused = false

    /// macOS ties the system audio permission to the code signature that asked for it, but
    /// System Settings shows one row per app. So when another copy of the app (the direct
    /// download next to the App Store build) was allowed, the switch is on and this copy is
    /// still refused, until the row is removed and the permission asked for again.
    static let systemAudioHint = "Already on in System Settings? It may belong to another copy of Digisensus Recorder. "
        + "Select Digisensus Recorder there, remove it with the − button, then allow it again."
    private nonisolated static let askedSystemAudioKey = "askedSystemAudio"

    /// Asks macOS for system audio; false when it's refused.
    @discardableResult
    nonisolated static func requestSystemAudio() -> Bool {
        UserDefaults.standard.set(true, forKey: askedSystemAudioKey)
        return CGRequestScreenCaptureAccess()
    }

    private var observer: NSObjectProtocol?
    private var poll: Timer?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone: return microphone
        case .systemAudio: return systemAudio
        case .notifications: return notifications
        }
    }

    var missing: [Kind] { Kind.allCases.filter { !isGranted($0) } }
    var requiredGranted: Bool { microphone && systemAudio }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudio = CGPreflightScreenCaptureAccess()
        let refused = !systemAudio && UserDefaults.standard.bool(forKey: Self.askedSystemAudioKey)
        if refused != systemAudioRefused { systemAudioRefused = refused }
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            // DSREC_DEMO: screenshots of a set-up Mac, from a test bundle that was never allowed.
            notifications = status == .authorized || status == .provisional
                || ProcessInfo.processInfo.environment["DSREC_DEMO"] != nil
        }
    }

    /// Checks every second, for screens that wait on System Settings.
    func startWatching() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        poll?.invalidate()
        poll = nil
    }

    /// Asks macOS; once the user has answered, only System Settings can change it.
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
            // Shows the system prompt the first time; after that it only registers the app
            // in the list, where the user has to switch it on.
            if !Self.requestSystemAudio() { openSettings(for: kind) }
            refresh()
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
        }
    }

    func openSettings(for kind: Kind) {
        let url = kind == .notifications
            ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
            : "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
