import AppKit
import UserNotifications

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

@MainActor
final class MessageCenter: ObservableObject {
    @Published private(set) var messages: [BroadcastMessage] = []
    @Published private(set) var read: Set<Int64> = []
    @Published var selected: Int64?

    var open: (Int64) -> Void = { _ in }
    var showBanner: (BroadcastMessage) -> Void = { _ in }

    var unreadCount: Int { messages.count { !read.contains($0.id) } }

    private static let interval: TimeInterval = {
        if let value = ProcessInfo.processInfo.environment["DSREC_MESSAGES_POLL"], let seconds = Double(value), seconds >= 5 {
            return seconds
        }
        return 15 * 60
    }()
    private static let announceWithin: TimeInterval = 7 * 24 * 3600
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

    func start() {
        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                await self?.poll()
            }
        }
    }

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        var request = URLRequest(url: DigisensusAccount.server.appendingPathComponent("v1/messages"), timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
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

    nonisolated static let messageIDKey = "messageID"

    private static func notificationID(_ id: Int64) -> String { "message-\(id)" }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
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
