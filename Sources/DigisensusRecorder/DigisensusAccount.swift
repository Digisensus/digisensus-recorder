import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case digisensus
    case custom

    var id: String { rawValue }
    var label: String { self == .digisensus ? "Digisensus" : "Own server" }

    static func explainsRefusal(status: Int) -> Bool {
        [401, 402, 403, 426, 429].contains(status)
    }
}

extension URLRequest {
    mutating func authorize(apiKey: String, provider: AIProvider) {
        if !apiKey.isEmpty { setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if provider == .digisensus { AppVersion.tag(&self) }
    }
}

@MainActor
final class DigisensusAccount: ObservableObject {
    static let server: URL = {
        if let value = ProcessInfo.processInfo.environment["DIGISENSUS_SERVER"], let url = URL(string: value) {
            return url
        }
        return URL(string: "https://recorder.digisensus.com")!
    }()
    static let trainingNotice = "Only your voice: recordings made with free credit may be used to train speech recognition "
        + "on your microphone channel, never on other speakers. Turn it off any time; your free credit stays the same."
    static var termsURL: URL { server.appendingPathComponent("tos") }
    static var privacyURL: URL { server.appendingPathComponent("privacy") }

    enum State: Equatable {
        case signedOut
        case sending
        case waiting(email: String, expires: Date)
        case signedIn(email: String)
    }

    struct Balance: Equatable {
        var free: Double
        var paid: Double
        var dailyFree: Double
        var resetsAt: Date?
        var referral: Double = 0
        var referralLots: [ReferralLot] = []
        var canSpend: Bool
    }

    struct ReferralLot: Equatable {
        var remaining: Double
        var expiresAt: Date
    }

    struct Referral: Equatable {
        struct Friend: Equatable, Identifiable {
            var id: String { "\(masked)-\(createdAt.timeIntervalSince1970)" }
            var masked: String
            var status: String
            var createdAt: Date
        }
        var agreed: Bool
        var termsVersion: String
        var termsURL: URL?
        var reward: Double
        var maxPerYear: Int
        var code: String?
        var link: URL?
        var friends: [Friend]
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var balance: Balance?
    @Published private(set) var trainingEnabled = true
    private var trainingConfirmed = true
    private var trainingSave: Task<Void, Never>?
    @Published private(set) var referral: Referral?
    @Published private(set) var referralTermsURL: URL?
    @Published private(set) var referralReward: Double = 5
    private var referralTermsVersion: String?
    private var pendingInviteCode = ""
    @Published private(set) var message: String?
    @Published private(set) var models: [String: [String]] = [:]

    private static let tokenAccount = "digisensus-device-token"
    private static let emailKey = "digisensusEmail"
    private var token: String?
    private var pollTask: Task<Void, Never>?

    init() {
        token = Keychain.string(Self.tokenAccount)
        if token != nil, let email = UserDefaults.standard.string(forKey: Self.emailKey) {
            state = .signedIn(email: email)
            Task { await refresh() }
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var deviceToken: String? { isSignedIn ? token : nil }

    var spendingBlock: String? {
        guard let balance, !balance.canSpend else { return nil }
        guard let resets = balance.resetsAt, resets > Date() else { return nil }
        return "Today's free Digisensus credit is used up. It renews at \(resets.formatted(date: .omitted, time: .shortened))."
    }

    func model(for kind: String, fallback: String) -> String {
        models[kind]?.first ?? fallback
    }

    static var defaultReferralTermsURL: URL { server.appendingPathComponent("referral-terms") }

    func register(email: String, referralCode: String = "") {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = referralCode.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingInviteCode = code
        pollTask?.cancel()
        state = .sending
        message = nil
        pollTask = Task {
            do {
                let config = try await call("GET", "v1/auth/config")
                guard let terms = config.json["tos_version"] as? String else { throw AccountError.unexpected }
                readReferralConfig(config.json)
                var body: [String: Any] = [
                    "email": email, "tos_version": terms, "device_name": Host.current().localizedName ?? "Mac",
                ]
                if !code.isEmpty {
                    body["referral_code"] = code
                    body["referral_terms_version"] = referralTermsVersion ?? ""
                }
                let reply = try await call("POST", "v1/auth/register", body: body)
                guard reply.status == 201,
                      let id = reply.json["registration_id"] as? String,
                      let secret = reply.json["poll_secret"] as? String else {
                    throw AccountError.server(reply.message ?? "Couldn't start signing in (\(reply.status)).")
                }
                let expires = (reply.json["expires_at"] as? String).flatMap(Self.parseDate) ?? Date().addingTimeInterval(1800)
                let interval = max(reply.json["poll_interval"] as? Double ?? 2, 1)
                state = .waiting(email: email, expires: expires)
                try await poll(id: id, secret: secret, email: email, expires: expires, interval: interval)
            } catch is CancellationError {
            } catch {
                state = .signedOut
                message = error.localizedDescription
            }
        }
    }

    func resend(to email: String) {
        register(email: email, referralCode: pendingInviteCode)
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        state = .signedOut
        message = nil
    }

    private func poll(id: String, secret: String, email: String, expires: Date, interval: Double) async throws {
        while Date() < expires.addingTimeInterval(30) {
            try await Task.sleep(for: .seconds(interval))
            let reply: Reply
            do {
                reply = try await call("POST", "v1/auth/registrations/\(id)/poll", bearer: secret)
            } catch let error as URLError where error.code != .cancelled {
                continue
            }
            switch reply.status {
            case 202, 429:
                continue
            case 200:
                guard let token = reply.json["api_token"] as? String else { throw AccountError.unexpected }
                let email = reply.json["email"] as? String ?? email
                self.token = token
                Keychain.set(token, for: Self.tokenAccount)
                UserDefaults.standard.set(email, forKey: Self.emailKey)
                state = .signedIn(email: email)
                trainingConfirmed = reply.json["training_enabled"] as? Bool ?? true
                trainingEnabled = trainingConfirmed
                Log.write("signed in to Digisensus")
                switch reply.json["referral"] as? String {
                case "pending":
                    message = "Invite accepted. You and your friend each get \(Self.credit(referralReward)) after your first transcription of a minute or more."
                case "not_eligible":
                    message = "Signed in. The invite code only applies to new Digisensus users, so no referral credit this time."
                default:
                    break
                }
                await refresh()
                return
            default:
                throw AccountError.server(reply.message ?? "Signing in failed (\(reply.status)).")
            }
        }
        throw AccountError.server("The confirmation link expired. Send a new one.")
    }

    func refresh() async {
        guard let token = deviceToken else { return }
        do {
            let account = try await call("GET", "v1/account", bearer: token)
            if account.status == 401 || account.status == 403 {
                forgetToken()
                message = account.message ?? "You were signed out. Sign in again."
                return
            }
            guard account.status == 200 else { return }
            let j = account.json
            func amount(_ name: String) -> Double { j["\(name)_d"] as? Double ?? 0 }
            balance = Balance(
                free: amount("free"),
                paid: amount("paid"),
                dailyFree: amount("daily_free"),
                resetsAt: (j["resets_at"] as? String).flatMap(Self.parseDate),
                referral: amount("referral"),
                referralLots: Self.lots(j["referral_lots"]),
                canSpend: !((j["tier"] as? String) ?? "").isEmpty)
            if let email = j["email"] as? String, case .signedIn(let current) = state, current != email {
                state = .signedIn(email: email)
            }
            if trainingSave == nil {
                trainingConfirmed = j["training_enabled"] as? Bool ?? true
                trainingEnabled = trainingConfirmed
            }

            let list = try await call("GET", "v1/models", bearer: token)
            var byKind: [String: [String]] = [:]
            for model in list.json["data"] as? [[String: Any]] ?? [] {
                if let id = model["id"] as? String, let kind = model["kind"] as? String {
                    byKind[kind, default: []].append(id)
                }
            }
            models = byKind
        } catch {
            Log.write("account refresh failed: \(error)")
        }
    }

    func refreshReferral() async {
        guard let token = deviceToken else { return }
        guard let reply = try? await call("GET", "v1/referral", bearer: token), reply.status == 200,
              deviceToken == token else { return }
        referral = Self.referral(from: reply.json)
    }

    func agreeToReferralTerms() {
        guard let token = deviceToken else { return }
        Task {
            do {
                let version: String
                if let known = referral?.termsVersion ?? referralTermsVersion {
                    version = known
                } else {
                    let config = try await call("GET", "v1/auth/config")
                    readReferralConfig(config.json)
                    version = referralTermsVersion ?? ""
                }
                var reply = try await call("POST", "v1/referral/agree", bearer: token, body: ["terms_version": version])
                if reply.status == 400, (reply.json["error"] as? [String: Any])?["code"] as? String == "referral_terms_outdated",
                   let current = reply.json["terms_version"] as? String
                    ?? (reply.json["error"] as? [String: Any])?["terms_version"] as? String {
                    referralTermsVersion = current
                    reply = try await call("POST", "v1/referral/agree", bearer: token, body: ["terms_version": current])
                }
                guard reply.status == 200 else {
                    throw AccountError.server(reply.message ?? "Couldn't get an invite link (\(reply.status)).")
                }
                guard deviceToken == token else { return }
                referral = Self.referral(from: reply.json)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func readReferralConfig(_ json: [String: Any]) {
        guard let info = json["referral"] as? [String: Any] else { return }
        referralTermsVersion = info["terms_version"] as? String
        referralTermsURL = (info["terms_url"] as? String).flatMap(URL.init(string:))
        referralReward = info["reward_d"] as? Double ?? referralReward
    }

    private static func referral(from j: [String: Any]) -> Referral {
        let friends = (j["referrals"] as? [[String: Any]] ?? []).compactMap { item -> Referral.Friend? in
            guard let masked = item["friend"] as? String, let status = item["status"] as? String else { return nil }
            return Referral.Friend(masked: masked, status: status,
                                   createdAt: (item["created_at"] as? String).flatMap(parseDate) ?? Date())
        }
        return Referral(agreed: j["agreed"] as? Bool ?? false,
                        termsVersion: j["terms_version"] as? String ?? "",
                        termsURL: (j["terms_url"] as? String).flatMap(URL.init(string:)),
                        reward: j["reward_d"] as? Double ?? 5,
                        maxPerYear: j["max_per_year"] as? Int ?? 20,
                        code: j["code"] as? String,
                        link: (j["link"] as? String).flatMap(URL.init(string:)),
                        friends: friends)
    }

    private static func lots(_ value: Any?) -> [ReferralLot] {
        (value as? [[String: Any]] ?? []).compactMap { lot in
            guard let remaining = lot["remaining_d"] as? Double,
                  let expires = (lot["expires_at"] as? String).flatMap(parseDate) else { return nil }
            return ReferralLot(remaining: remaining, expiresAt: expires)
        }.sorted { $0.expiresAt < $1.expiresAt }
    }

    static func credit(_ amount: Double) -> String {
        amount.formatted(.number.precision(.fractionLength(2))) + " D"
    }

    func signOut() {
        if let token {
            Task { _ = try? await call("DELETE", "v1/auth/token", bearer: token) }
        }
        forgetToken()
    }

    func setTraining(enabled: Bool) {
        guard let token = deviceToken else { return }
        trainingEnabled = enabled
        trainingSave?.cancel()
        let save = Task { [weak self] in
            var reply: Reply?
            var failure: String?
            do {
                reply = try await self?.call("PATCH", "v1/account", bearer: token, body: ["training_enabled": enabled])
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled, deviceToken == token else { return }
            trainingSave = nil
            if let reply, reply.status == 200 {
                trainingConfirmed = enabled
                Log.write("training \(enabled ? "on" : "off")")
            } else {
                trainingEnabled = trainingConfirmed
                message = failure ?? reply?.message ?? "Couldn't save the setting (\(reply?.status ?? 0))."
            }
        }
        trainingSave = save
    }

    func deleteAccount() {
        guard let token = deviceToken else { return }
        Task {
            do {
                let reply = try await call("DELETE", "v1/account", bearer: token)
                guard reply.status == 204 else {
                    message = reply.message ?? "Couldn't delete the account (\(reply.status))."
                    return
                }
                forgetToken()
                message = "Your Digisensus account was deleted."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func forgetToken() {
        trainingSave?.cancel()
        trainingSave = nil
        trainingConfirmed = true
        trainingEnabled = true
        token = nil
        Keychain.set(nil, for: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        balance = nil
        models = [:]
        referral = nil
        pendingInviteCode = ""
        state = .signedOut
    }

    private struct Reply {
        var status: Int
        var json: [String: Any]
        var message: String? { (json["error"] as? [String: Any])?["message"] as? String }
    }

    private enum AccountError: LocalizedError {
        case server(String)
        case unexpected
        var errorDescription: String? {
            switch self {
            case .server(let message): return message
            case .unexpected: return "The Digisensus service sent an unexpected answer."
            }
        }
    }

    private func call(_ method: String, _ path: String, bearer: String? = nil, body: [String: Any]? = nil) async throws -> Reply {
        var request = URLRequest(url: Self.server.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        AppVersion.tag(&request)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Reply(status: status, json: json)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
