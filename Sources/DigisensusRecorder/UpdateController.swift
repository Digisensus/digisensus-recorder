import AppKit
import Combine
import CryptoKit
import IOKit
#if !APP_STORE
import Sparkle
#endif

/// How this copy of the app reached the Mac, decided when it was built: `package.sh` makes the
/// direct download (Developer ID, updates itself over the air), `package-appstore.sh` the Mac
/// App Store build (sandboxed, no updater: the App Store updates it).
enum AppDistribution: String {
    case direct
    case appStore = "appstore"

    #if APP_STORE
    static let current = AppDistribution.appStore
    #else
    static let current = AppDistribution.direct
    #endif
}

/// This build, as the backend sees it.
enum AppVersion {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    /// Posted when the Digisensus backend refuses this build as too old (426).
    static let updateRequired = Notification.Name("DigisensusRecorderUpdateRequired")

    /// Tells the Digisensus backend which build is asking and how it is updated, so it can
    /// require an update (and give App Store users time for Apple's review). The device ID is
    /// for the referral program's fraud checks (see its terms).
    static func tag(_ request: inout URLRequest) {
        request.setValue(build, forHTTPHeaderField: "X-App-Build")
        request.setValue(AppDistribution.current.rawValue, forHTTPHeaderField: "X-App-Distribution")
        if let deviceID { request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID") }
    }

    /// A one-way ID for this Mac: SHA-256 of its hardware UUID with an app-specific prefix, so
    /// it means nothing anywhere else. The hardware UUID itself never leaves the Mac.
    static let deviceID: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        return SHA256.hash(data: Data("digisensus-recorder-device:\(uuid)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }()

    static func noteRefusal(status: Int) {
        if status == 426 { NotificationCenter.default.post(name: updateRequired, object: nil) }
    }
}

/// Keeps the app current. The direct download updates itself over the air (Sparkle): it checks
/// at every launch and every 24 hours, downloads in the background, and installs at a quiet
/// moment (no recording, no call for a while, nothing being transcribed) by relaunching into the
/// new version. The feed comes from the Digisensus backend, which decides what each channel is
/// offered. The App Store build has no updater; it only points to the App Store when the
/// backend says this version is too old.
///
/// Only release builds update: `package.sh` keeps the Sparkle public key in Info.plist, while
/// `build.sh` removes it, so local builds never replace themselves with a release.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    /// An update found or downloaded, waiting for the user or a quiet moment.
    struct Pending: Equatable {
        let version: String
        /// Downloaded and ready: installing is just a relaunch.
        let isReady: Bool
    }

    /// Updates itself: a direct release build. False for local builds and the App Store.
    let isEnabled: Bool
    @Published private(set) var pending: Pending?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var canCheck = false
    /// The backend refused this version (App Store build: update there to go on).
    @Published private(set) var isOutdated = false

    /// Download and install without asking. Off: an available update is only announced.
    @Published var installsAutomatically: Bool {
        didSet { setAutomaticDownloads(installsAutomatically) }
    }

    /// Beta releases as well as stable ones.
    @Published var includesBetas = UserDefaults.standard.bool(forKey: "updateBetas") {
        didSet {
            UserDefaults.standard.set(includesBetas, forKey: "updateBetas")
            restartUpdateCycle()
        }
    }

    /// How long nothing call-related must have happened before an update relaunches the app.
    /// (DSREC_UPDATE_QUIET=<seconds> shortens it for testing.)
    private static let quietPeriod: TimeInterval =
        ProcessInfo.processInfo.environment["DSREC_UPDATE_QUIET"].flatMap(TimeInterval.init) ?? 10 * 60

    /// Where "Update in the App Store" goes: the app's own page once Info.plist has its App
    /// Store ID (DSAppStoreID), until then the store's Updates page.
    static var appStoreURL: URL {
        if let id = Bundle.main.object(forInfoDictionaryKey: "DSAppStoreID") as? String, !id.isEmpty {
            return URL(string: "macappstore://apps.apple.com/app/id\(id)")!
        }
        return URL(string: "macappstore://showUpdatesPage")!
    }

    private let model: RecorderModel
    /// Sparkle's go-ahead for the downloaded update, kept until the app is quiet.
    private var installWhenQuiet: (() -> Void)?
    private var quietTimer: Timer?
    private var lastBusy = Date()
    private var observers: Set<AnyCancellable> = []
    #if !APP_STORE
    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }
    #endif

    init(model: RecorderModel) {
        self.model = model
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isEnabled = AppDistribution.current == .direct && !key.isEmpty
        installsAutomatically = UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
        super.init()
        guard isEnabled else { return }
        #if !APP_STORE
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                      userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        updater.updateCheckInterval = 24 * 60 * 60
        updater.automaticallyDownloadsUpdates = installsAutomatically
        controller.startUpdater()
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observers)
        lastCheck = updater.lastUpdateCheckDate
        // Every launch, not only once the 24 hours are up.
        updater.checkForUpdatesInBackground()
        quietTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
        #endif
    }

    /// Checks now and shows what it finds (Check for Updates…).
    func checkNow() {
        #if APP_STORE
        openAppStore()
        #else
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
        #endif
    }

    /// Installs the update that is ready now (Restart to Update), or shows the one found.
    func installNow() {
        if let install = installWhenQuiet {
            installWhenQuiet = nil
            install()
        } else {
            checkNow()
        }
    }

    func openAppStore() {
        NSWorkspace.shared.open(Self.appStoreURL)
    }

    /// The backend refused a request because this version is too old. Direct: look at once, so
    /// the (critical) update is offered straight away. App Store: say so, with a way there.
    func updateRequired() {
        isOutdated = true
        #if !APP_STORE
        updater?.checkForUpdatesInBackground()
        #endif
    }

    private func setAutomaticDownloads(_ on: Bool) {
        #if !APP_STORE
        updater?.automaticallyDownloadsUpdates = on
        #endif
    }

    private func restartUpdateCycle() {
        #if !APP_STORE
        updater?.resetUpdateCycleAfterShortDelay()
        #endif
    }

    /// Quiet: nothing recording or compressing, no transcript or summary on the way, and no
    /// call noticed for a while. A relaunch then costs nothing.
    private var isQuiet: Bool {
        let library = model.library
        let busy = model.isRecording || model.isBusy
            || !library.transcribing.isEmpty || !library.summarizing.isEmpty
        if busy { lastBusy = Date() }
        let lastActivity = max(lastBusy, model.lastCallSeen ?? .distantPast)
        return !busy && Date().timeIntervalSince(lastActivity) > Self.quietPeriod
    }

    /// Only while automatic installs are on; turned off, a downloaded update waits for Restart
    /// to Update.
    private func installIfQuiet() {
        guard installsAutomatically, isQuiet, let install = installWhenQuiet else { return }
        installWhenQuiet = nil
        Log.write("update: installing \(pending?.version ?? "?") now that the app is quiet")
        install()
    }
}

#if !APP_STORE
extension UpdateController: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let channel = UserDefaults.standard.bool(forKey: "updateBetas") ? "beta" : "stable"
        let server = MainActor.assumeIsolated { DigisensusAccount.server }
        return server.appendingPathComponent("v1/app/appcast.xml").absoluteString + "?channel=\(channel)"
    }

    /// Automatic checks are on by design; never ask.
    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// A silently downloaded update would otherwise wait for the app to quit, which a menu bar
    /// app rarely does. Keep the go-ahead and use it at the next quiet moment.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            installWhenQuiet = immediateInstallationBlock
            pending = Pending(version: version, isReady: true)
            Log.write("update: \(version) downloaded, waiting for a quiet moment")
        }
        return true
    }

    /// Never relaunch in the middle of a call, even when the user clicked Install.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard model.isRecording || model.isBusy else { return false }
            installWhenQuiet = installHandler
            pending = Pending(version: item.displayVersionString, isReady: true)
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            if pending == nil { pending = Pending(version: version, isReady: false) }
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            if installWhenQuiet == nil { pending = nil }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: (any Error)?) {
        // Sparkle calls its delegate on the main thread.
        MainActor.assumeIsolated { lastCheck = updater.lastUpdateCheckDate }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.write("update check failed: \(error.localizedDescription)")
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    /// A menu bar app shouldn't pop update windows on its own: scheduled finds show as a row in
    /// the menu bar panel and in Settings instead (Sparkle's "gentle reminders").
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Critical updates (including "this version is no longer supported") always show.
        update.isCriticalUpdate
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if installWhenQuiet == nil { pending = Pending(version: version, isReady: false) }
            // Sparkle's own window is about to open; bring a menu-bar-only app forward for it.
            if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
#endif
