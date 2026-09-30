import AppKit
import UserNotifications

/// A message from Digisensus to every install of the app, written in the backend's admin UI.
/// `html` is the body, already rendered (and escaped) by the backend; uploaded images are
/// paths on the server.
struct BroadcastMessage: Codable, Identifiable, Equatable {
    let id: Int64
    let title: String
    let summary: String
    let html: String
    let publishedAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, summary, html
        case publishedAt = "published_at"
        case updatedAt = "updated_at"
    }
}

/// Fetches the messages from the Digisensus backend (GET /v1/messages, no account needed) at
/// launch, on wake and every 15 minutes, and tells the user about new ones: a system
/// notification with the title (and summary) whose click opens the Messages window, or, with
/// notifications off, the in-app banner. The last list is kept so the window works offline.
@MainActor
final class MessageCenter: ObservableObject {
    @Published private(set) var messages: [BroadcastMessage] = []
    @Published private(set) var read: Set<Int64> = []
    /// The message the Messages window shows.
    @Published var selected: Int64?

    /// Opens the Messages window on a message (the banner's button).
    var open: (Int64) -> Void = { _ in }
    /// Shows a message in the in-app banner, for when system notifications are off.
    var showBanner: (BroadcastMessage) -> Void = { _ in }

    var unreadCount: Int { messages.count { !read.contains($0.id) } }

    /// DSREC_MESSAGES_POLL=<seconds> checks more often, for testing.
    private static let interval: TimeInterval = {
        if let value = ProcessInfo.processInfo.environment["DSREC_MESSAGES_POLL"], let seconds = Double(value), seconds >= 5 {
            return seconds
        }
        return 15 * 60
    }()
    /// Only messages this recent are announced; older ones (say, on a new install) are only
    /// listed in the window.
    private static let announceWithin: TimeInterval = 7 * 24 * 3600
    /// At most this many notifications at once.
    private static let announceMax = 3

    private enum Key {
        static let cache = "messagesCache"
        static let notifiedThrough = "messagesNotifiedThrough"
        static let read = "messagesRead"
    }

    private struct Cache: Codable {
        var etag: String?
        var messages: [BroadcastMessage]
    }

    private var etag: String?
    private var timer: Timer?
    private var polling = false
    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: Key.cache), let cache = try? Self.decoder.decode(Cache.self, from: data) {
            messages = cache.messages
            etag = cache.etag
        }
        read = Set((defaults.array(forKey: Key.read) as? [NSNumber] ?? []).map(\.int64Value))
    }

    /// Checks now, then every 15 minutes and after each wake from sleep.
    func start() {
        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10)) // the network comes back after the wake
                await self?.poll()
            }
        }
    }

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        var request = URLRequest(url: DigisensusAccount.server.appendingPathComponent("v1/messages"), timeoutInterval: 20)
        // Our own ETag, not URLCache's copy: a 304 then means nothing changed.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // The build, as on every request; no device ID, which only the account's calls need.
        request.setValue(AppVersion.build, forHTTPHeaderField: "X-App-Build")
        request.setValue(AppDistribution.current.rawValue, forHTTPHeaderField: "X-App-Distribution")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode {
            case 200:
                let list = try Self.decoder.decode([String: [BroadcastMessage]].self, from: data)["messages"] ?? []
                update(list, etag: http?.value(forHTTPHeaderField: "ETag"))
            case 304:
                break
            default:
                Log.write("messages: server answered \(http?.statusCode ?? 0)")
            }
        } catch {
            Log.write("messages: \(error.localizedDescription)")
        }
    }

    func markRead(_ id: Int64?) {
        guard let id, messages.contains(where: { $0.id == id }), !read.contains(id) else { return }
        read.insert(id)
        saveRead()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID(id)])
    }

    /// Development hook (DSREC_SNAPSHOT): a sample to render.
    func showSample(_ message: BroadcastMessage) {
        messages = [message]
        selected = message.id
    }

    private func update(_ list: [BroadcastMessage], etag: String?) {
        let gone = Set(messages.map(\.id)).subtracting(list.map(\.id))
        messages = list
        self.etag = etag
        if let data = try? Self.encoder.encode(Cache(etag: etag, messages: list)) {
            defaults.set(data, forKey: Key.cache)
        }
        if !gone.isEmpty {
            // Withdrawn: take its notification back from Notification Centre too.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone.map(Self.notificationID))
            if let selected, gone.contains(selected) { self.selected = nil }
        }
        read.formIntersection(list.map(\.id))
        saveRead()

        let notifiedThrough = (defaults.object(forKey: Key.notifiedThrough) as? NSNumber)?.int64Value ?? 0
        let fresh = list.filter { $0.id > notifiedThrough }
        guard let newest = fresh.map(\.id).max() else { return }
        defaults.set(NSNumber(value: newest), forKey: Key.notifiedThrough)
        let announce = fresh
            .filter { Date().timeIntervalSince($0.publishedAt) < Self.announceWithin }
            .sorted { $0.id > $1.id }
            .prefix(Self.announceMax)
        if !announce.isEmpty {
            Task { await self.announce(Array(announce)) }
        }
    }

    /// A notification for each message, newest first; the banner for the newest one when the
    /// user turned notifications off (asking first if they were never asked).
    private func announce(_ list: [BroadcastMessage]) async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.write("messages: notification permission: \(error.localizedDescription)")
            }
            settings = await center.notificationSettings()
        }
        let allowed = [.authorized, .provisional].contains(settings.authorizationStatus) && settings.alertSetting == .enabled
        guard allowed else {
            Log.write("messages: notifications are off (status \(settings.authorizationStatus.rawValue), "
                + "alerts \(settings.alertSetting.rawValue)); showing message \(list[0].id) in the banner")
            showBanner(list[0])
            return
        }
        for message in list {
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.summary
            content.sound = .default
            content.threadIdentifier = "messages"
            content.userInfo = [Self.messageIDKey: NSNumber(value: message.id)]
            do {
                try await center.add(UNNotificationRequest(identifier: Self.notificationID(message.id), content: content, trigger: nil))
                Log.write("messages: notified message \(message.id)")
            } catch {
                Log.write("messages: notification failed: \(error.localizedDescription)")
            }
        }
    }

    private func saveRead() {
        defaults.set(read.sorted().map { NSNumber(value: $0) }, forKey: Key.read)
    }

    /// The key in a message notification's userInfo that holds its id.
    nonisolated static let messageIDKey = "messageID"

    private static func notificationID(_ id: Int64) -> String { "message-\(id)" }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            // The backend sends fractional seconds; the cache doesn't.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(string)"))
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
