import AppKit
import Combine
import CryptoKit
import IOKit
#if !APP_STORE
import Sparkle
#endif

enum AppDistribution: String {
    case direct
    case appStore = "appstore"

    #if APP_STORE
    static let current = AppDistribution.appStore
    #else
    static let current = AppDistribution.direct
    #endif
}

enum AppVersion {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    static let updateRequired = Notification.Name("DigisensusRecorderUpdateRequired")

    static func tag(_ request: inout URLRequest) {
        request.setValue(build, forHTTPHeaderField: "X-App-Build")
        request.setValue(AppDistribution.current.rawValue, forHTTPHeaderField: "X-App-Distribution")
        if let deviceID { request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID") }
    }

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

@MainActor
final class UpdateController: NSObject, ObservableObject {
    struct Pending: Equatable {
        let version: String
        let isReady: Bool
    }

    let isEnabled: Bool
    @Published private(set) var pending: Pending?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var canCheck = false
    @Published private(set) var isOutdated = false

    @Published var installsAutomatically: Bool {
        didSet { setAutomaticDownloads(installsAutomatically) }
    }

    @Published var includesBetas = UserDefaults.standard.bool(forKey: "updateBetas") {
        didSet {
            UserDefaults.standard.set(includesBetas, forKey: "updateBetas")
            restartUpdateCycle()
        }
    }

    private static let quietPeriod: TimeInterval =
        ProcessInfo.processInfo.environment["DSREC_UPDATE_QUIET"].flatMap(TimeInterval.init) ?? 10 * 60

    static var appStoreURL: URL {
        if let id = Bundle.main.object(forInfoDictionaryKey: "DSAppStoreID") as? String, !id.isEmpty {
            return URL(string: "macappstore://apps.apple.com/app/id\(id)")!
        }
        return URL(string: "macappstore://showUpdatesPage")!
    }

    private let model: RecorderModel
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
        updater.checkForUpdatesInBackground()
        quietTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
        #endif
    }

    func checkNow() {
        #if APP_STORE
        openAppStore()
        #else
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
        #endif
    }

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

    private var isQuiet: Bool {
        let library = model.library
        let busy = model.isRecording || model.isBusy
            || !library.transcribing.isEmpty || !library.summarizing.isEmpty
        if busy { lastBusy = Date() }
        let lastActivity = max(lastBusy, model.lastCallSeen ?? .distantPast)
        return !busy && Date().timeIntervalSince(lastActivity) > Self.quietPeriod
    }

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

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

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
        MainActor.assumeIsolated { lastCheck = updater.lastUpdateCheckDate }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.write("update check failed: \(error.localizedDescription)")
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        update.isCriticalUpdate
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if installWhenQuiet == nil { pending = Pending(version: version, isReady: false) }
            if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
#endif
