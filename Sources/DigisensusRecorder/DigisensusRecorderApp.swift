import Combine
import SwiftUI
import UserNotifications

@main
struct DigisensusRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.openSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = RecorderModel()
    private(set) lazy var agents = AgentAccess(model: model)
    private(set) lazy var updates = UpdateController(model: model)
    let messages = MessageCenter()
    private let permissions = Permissions()
    private let navigation = AppNavigation()
    private let popover = NSPopover()
    private let banner = BannerPresenter()
    private let dot = CALayer()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var messagesWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingFlow: OnboardingFlow?
    private let mainToolbar = MainToolbar()
    private var observers: Set<AnyCancellable> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PlayerModel.clearCache()
        _ = agents
        _ = updates
        announceUpdate()
        NotificationCenter.default.addObserver(forName: AppVersion.updateRequired, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updates.updateRequired() }
        }
        let environment = ProcessInfo.processInfo.environment
        let snapshotFolder = environment["DSREC_SNAPSHOT"]
        if let snapshotFolder {
            Task { await snapshotUI(into: URL(fileURLWithPath: snapshotFolder)) }
        }
        navigation.openSettings = { [weak self] tab in self?.openSettings(tab) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.wantsLayer = true
        item.button?.layer?.addSublayer(dot)
        statusItem = item

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel(
            model: model, library: model.library, updates: updates,
            openApp: { [weak self] in self?.openMainWindow() },
            openCall: { [weak self] id in self?.openCall(id) },
            openSettings: { [weak self] in self?.openSettings() },
            messages: messages,
            openMessages: { [weak self] in self?.openMessages() }))

        messages.open = { [weak self] id in self?.openMessages(id) }
        messages.showBanner = { [weak self] message in self?.showMessageBanner(message) }
        if snapshotFolder == nil {
            messages.start()
        }

        applyDockPreference()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDockPreference() }
        }
        let onceMore = UserDefaults.standard.bool(forKey: OnboardingFlow.onceMoreKey)
        if onceMore { UserDefaults.standard.removeObject(forKey: OnboardingFlow.onceMoreKey) }
        if onceMore || environment["DSREC_ONBOARDING"] != nil || !UserDefaults.standard.bool(forKey: OnboardingFlow.doneKey) {
            showOnboarding()
        } else if !Self.launchedAtLogin, snapshotFolder == nil {
            openMainWindow()
        }

        model.$isRecording.combineLatest(model.$autoRecord)
            .sink { [weak self] recording, armed in self?.updateIcon(recording: recording, armed: armed) }
            .store(in: &observers)
        model.$isRecording.removeDuplicates().dropFirst().filter { $0 }
            .sink { [weak self] _ in self?.showStartedBanner() }
            .store(in: &observers)
        model.$lastSaved.compactMap { $0 }
            .sink { [weak self] file in self?.showSavedBanner(file) }
            .store(in: &observers)
        model.$lastDiscarded.compactMap { $0 }
            .sink { [weak self] label in
                self?.banner.show(.init(symbol: "phone.down.circle.fill", tint: .secondary, title: "\(label) call not answered",
                                        detail: "Nobody spoke, so nothing was kept."), for: 6)
            }
            .store(in: &observers)
    }

    private func showStartedBanner() {
        let model = model
        banner.show(.init(symbol: "record.circle.fill", tint: .red, title: "Recording started",
                          detail: model.recordingName ?? "",
                          button: "Stop", action: { model.toggle() }), for: 6)
    }

    private func showSavedBanner(_ file: URL) {
        banner.show(.init(symbol: "checkmark.circle.fill", tint: .green, title: "Recording saved",
                          detail: file.lastPathComponent, button: "View", action: { [weak self] in
            guard let self else { return }
            let library = model.library
            if let id = library.recordings.first(where: { $0.fileName == file.lastPathComponent })?.id
                ?? library.recordings.first?.id {
                openCall(id)
            } else {
                openMainWindow()
            }
        }), for: 8)
    }

    private func showMessageBanner(_ message: BroadcastMessage) {
        banner.show(.init(symbol: "megaphone.fill", tint: .blue, title: message.title,
                          detail: message.summary.isEmpty ? "A message from Digisensus" : message.summary,
                          button: "Open", action: { [weak self] in self?.openMessages(message.id) }), for: 12)
    }

    func applicationWillTerminate(_ notification: Notification) {
        agents.shutDown()
        model.stopBeforeQuit()
    }

    func openMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainView(
                model: model, library: model.library, navigation: navigation, permissions: permissions,
                agents: agents, updates: updates))
            let window = NSWindow(contentViewController: host)
            let toolbar = NSToolbar(identifier: "DigisensusRecorderMain")
            toolbar.delegate = mainToolbar
            toolbar.centeredItemIdentifiers = [MainToolbar.title]
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.title = "Digisensus Recorder"
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.setContentSize(NSSize(width: 1240, height: 780))
            window.collectionBehavior = Self.ownSpace
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DigisensusRecorderMainWindow.v2")
            if !window.setFrameUsingName("DigisensusRecorderMainWindow.v2") { window.center() }
            window.delegate = self
            mainWindow = window
        }
        show(mainWindow)
    }

    func openCall(_ id: Int64) {
        navigation.settingsTab = nil
        navigation.showingLive = false
        model.library.focus(on: id)
        openMainWindow()
    }

    func openMessages(_ id: Int64? = nil) {
        popover.performClose(nil)
        if let id {
            messages.selected = id
        } else if messages.selected == nil {
            messages.selected = messages.messages.first?.id
        }
        if messagesWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MessagesView(center: messages)))
            window.title = "Messages"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 900, height: 620))
            window.collectionBehavior = Self.ownSpace
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DigisensusRecorderMessagesWindow")
            if !window.setFrameUsingName("DigisensusRecorderMessagesWindow") { window.center() }
            window.delegate = self
            messagesWindow = window
        }
        show(messagesWindow)
    }

    func openSettings(_ tab: SettingsTab = .general) {
        navigation.settingsTab = tab
        openMainWindow()
    }

    private func showOnboarding() {
        let flow = OnboardingFlow()
        flow.finish = { [weak self] in self?.finishOnboarding() }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: OnboardingView(flow: flow, model: model, permissions: permissions)))
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Digisensus Recorder"
        window.isMovableByWindowBackground = true
        window.collectionBehavior = Self.ownSpace
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingFlow = flow
        onboardingWindow = window
        show(window)
    }

    private func finishOnboarding() {
        guard let flow = onboardingFlow else { return }
        OnboardingSetup.apply(flow, to: model)
        onboardingWindow?.close()
        openMainWindow()
    }

    private static let ownSpace: NSWindow.CollectionBehavior = [.fullScreenPrimary, .managed]

    private static var launchedAtLogin: Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static var showsInDock: Bool { UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true }

    private var hasVisibleWindow: Bool {
        [mainWindow, onboardingWindow, messagesWindow].contains { $0?.isVisible == true }
    }

    private func applyDockPreference() {
        let policy: NSApplication.ActivationPolicy = Self.showsInDock || hasVisibleWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func show(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(nil)
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Digisensus", action: #selector(openFromMenu), keyEquivalent: "").target = self
            if !messages.messages.isEmpty {
                let unread = messages.unreadCount
                menu.addItem(withTitle: unread > 0 ? "Messages (\(unread) new)" : "Messages",
                             action: #selector(messagesFromMenu), keyEquivalent: "").target = self
            }
            if updates.isEnabled || AppDistribution.current == .appStore {
                let title = updates.pending?.isReady == true ? "Restart to Update" : "Check for Updates…"
                menu.addItem(withTitle: title, action: #selector(updateFromMenu), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Digisensus Recorder", action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshDevices()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func openFromMenu() { openMainWindow() }
    @objc private func messagesFromMenu() { openMessages() }
    @objc private func updateFromMenu() { updates.installNow() }

    private func announceUpdate() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "lastRunVersion")
        defaults.set(AppVersion.version, forKey: "lastRunVersion")
        guard let previous, previous != AppVersion.version else { return }
        banner.show(.init(symbol: "arrow.down.circle.fill", tint: .blue, title: "Updated to \(AppVersion.version)",
                          detail: "Digisensus Recorder is up to date."), for: 6)
    }

    private func updateIcon(recording: Bool, armed: Bool) {
        guard let button = statusItem?.button else { return }
        let color: NSColor? = recording ? .systemRed : armed ? .systemBlue : nil
        button.image = color == nil ? MenuIcon.plain : MenuIcon.withDotGap

        dot.removeAllAnimations()
        dot.isHidden = color == nil
        guard let color else { return }

        let imageRect = button.cell.flatMap { ($0 as? NSButtonCell)?.imageRect(forBounds: button.bounds) }
            ?? button.bounds.insetBy(dx: (button.bounds.width - MenuIcon.canvas.width) / 2,
                                     dy: (button.bounds.height - MenuIcon.canvas.height) / 2)
        let gap = MenuIcon.dotRect
        let y = button.isFlipped ? imageRect.minY + MenuIcon.canvas.height - gap.maxY : imageRect.minY + gap.minY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = NSRect(x: imageRect.minX + gap.minX, y: y, width: gap.width, height: gap.height)
        dot.cornerRadius = gap.width / 2
        dot.backgroundColor = color.cgColor
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.25
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.75
        let pulse = CAAnimationGroup()
        pulse.animations = [fade, shrink]
        pulse.duration = recording ? 0.6 : 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
    }
}

enum MenuIcon {
    static let canvas = NSSize(width: 18, height: 18)
    static let dotRect = NSRect(x: 11.5, y: 11.5, width: 6.5, height: 6.5)
    private static let logoRect = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)

    private static let logo = NSImage(named: "MenuIcon")
        ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)!

    static let plain = template { _ in logo.draw(in: logoRect) }

    static let withDotGap = template { _ in
        logo.draw(in: logoRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setBlendMode(.clear)
        context.fillEllipse(in: dotRect.insetBy(dx: -1.5, dy: -1.5))
    }

    private static func template(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension AppDelegate {
    private func snapshotUI(into folder: URL) async {
        func write(_ window: NSWindow?, _ name: String) {
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(name).png"))
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))

        if onboardingWindow == nil { showOnboarding() }
        onboardingFlow?.signIn.inviteCode = "DGS-TEST-CODE"
        for step in 0..<OnboardingFlow.stepCount {
            onboardingFlow?.step = step
            try? await Task.sleep(for: .seconds(0.8))
            write(onboardingWindow, "onboarding-\(step + 1)")
        }
        onboardingWindow?.close()

        openMainWindow()
        let library = model.library
        library.showLatestDay()
        try? await Task.sleep(for: .seconds(5))
        write(mainWindow, "main-day")
        for tab in AppNavigation.DetailTab.allCases where tab != .summary {
            navigation.detailTab = tab
            try? await Task.sleep(for: .seconds(1))
            write(mainWindow, "main-\(tab.rawValue.lowercased())")
        }
        navigation.detailTab = .summary
        library.showAll()
        try? await Task.sleep(for: .seconds(1.5))
        write(mainWindow, "main-all")

        for tab in SettingsTab.allCases {
            openSettings(tab)
            try? await Task.sleep(for: .seconds(1))
            write(mainWindow, "settings-\(tab.rawValue + 1)")
        }
        navigation.settingsTab = nil

        await messages.poll()
        if let first = messages.messages.first {
            messages.selected = first.id
        } else {
            messages.showSample(BroadcastMessage(
                id: 1, title: "Live captions are here", summary: "See what you and the other side say as you speak.",
                html: "<h2>What's new</h2>\n<p>Digisensus Recorder now shows <strong>live captions</strong> during a call. "
                    + "<a href=\"https://digisensus.com\">Read more</a>.</p>\n<ul>\n<li>Both sides</li>\n<li>Lithuanian and English</li>\n</ul>\n",
                publishedAt: Date(), updatedAt: Date()))
        }
        openMessages()
        try? await Task.sleep(for: .seconds(2))
        write(messagesWindow, "messages")
        if let web = MessageWebView.current, let image = try? await web.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("messages-body.png"))
        }
        messagesWindow?.close()

        if let panel = popover.contentViewController?.view {
            panel.frame.size = panel.fittingSize
            panel.layoutSubtreeIfNeeded()
            if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("popover.png"))
            }
        }
        NSApp.terminate(nil)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo[MessageCenter.messageIDKey] as? NSNumber)?.int64Value else {
            return
        }
        await MainActor.run { self.openMessages(id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.userInfo[MessageCenter.messageIDKey] == nil ? [] : [.banner, .list, .sound]
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyDockPreference() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if onboardingWindow?.isVisible == true {
            show(onboardingWindow)
        } else {
            openMainWindow()
        }
        return false
    }
}

@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    nonisolated static let title = NSToolbarItem.Identifier("DigisensusRecorderTitle")

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.title]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.title]
    }

    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.title else { return nil }
        return MainActor.assumeIsolated {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Digisensus Recorder"
            item.isBordered = false
            item.view = NSHostingView(rootView: WindowTitle())
            return item
        }
    }
}

private struct WindowTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSImage(named: "TitleMark") ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
            Text("Digisensus Recorder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
