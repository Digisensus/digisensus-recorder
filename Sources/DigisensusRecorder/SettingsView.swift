import SwiftUI

/// Settings as a page in the main window, in the call's place: four tabs and Done.
struct SettingsPage: View {
    let tab: SettingsTab
    @ObservedObject var model: RecorderModel
    let permissions: Permissions
    let agents: AgentAccess
    let updates: UpdateController
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("Settings").font(.system(size: 20, weight: .bold)).fixedSize()
                    Spacer()
                    Button("Done") { navigation.settingsTab = nil }
                        .keyboardShortcut(.cancelAction)
                        .fixedSize()
                }
                Picker("Settings tab", selection: Binding(get: { tab }, set: { navigation.settingsTab = $0 })) {
                    ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
            Divider()
            Group {
                switch tab {
                case .general: GeneralSettings(model: model, library: model.library, permissions: permissions)
                case .ai: AISettings(library: model.library, account: model.library.account)
                case .advanced: AdvancedSettings(agents: agents, updates: updates)
                case .license: LicenseSettings()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var permissions: Permissions
    /// Read by AppDelegate.showsInDock.
    @AppStorage("showInDock") private var showInDock = true

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Your microphone", selection: $model.micID) {
                    ForEach(model.mics) { Text($0.name).tag($0.id) }
                }
                Picker("Other side", selection: $model.source) {
                    ForEach(model.apps) { Text($0.name).tag($0.source) }
                }
                Toggle(isOn: $model.cleanUpAudio) {
                    Text("Clean up audio")
                    Text("Evens out both voices and removes echo when you're not using headphones.")
                }
            }
            .disabled(model.isRecording)

            Section("Automation") {
                Toggle(isOn: $model.autoRecord) {
                    Text("Auto-record calls")
                    Text("Zoom, Meet, Teams, FaceTime and phone calls. Telling others is up to you.")
                }
                Toggle(isOn: $model.launchAtLogin) {
                    Text("Open at login")
                    Text("Starts quietly in the menu bar.")
                }
                Toggle(isOn: $showInDock) {
                    Text("Show in the Dock")
                    Text("Off, the app lives in the menu bar and appears in the Dock only while a window is open.")
                }
            }

            Section("Storage & permissions") {
                LabeledContent {
                    Button("Show in Finder", action: model.revealFolder)
                } label: {
                    Text(model.folder.path(percentEncoded: false)
                        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    Text(storageSummary)
                }
                HStack(spacing: 20) {
                    ForEach(Permissions.Kind.allCases) { kind in
                        HStack(spacing: 6) {
                            Image(systemName: permissions.isGranted(kind) ? "checkmark" : "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(permissions.isGranted(kind) ? Palette.good : Palette.recordInk)
                            Text(kind.name)
                        }
                    }
                    Spacer()
                    if let missing = permissions.missing.first {
                        Button("Allow \(missing.name)…") { permissions.request(missing) }
                    } else {
                        Text("All allowed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if permissions.systemAudioRefused {
                    Text(Permissions.systemAudioHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            model.refreshDevices()
            permissions.refresh()
        }
    }

    private var storageSummary: String {
        let recordings = library.recordings
        let bytes = recordings.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "Ogg Opus, under 11 MB per hour · \(recordings.count) recording\(recordings.count == 1 ? "" : "s"), "
            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: Transcription & AI

/// The sign-in form's fields. (A class rather than @State: see RecordingDraft.)
@MainActor
final class SignInForm: ObservableObject {
    @Published var email = UserDefaults.standard.string(forKey: "digisensusLastEmail") ?? ""
    @Published var acceptedTerms = false
    /// A friend's invite code or link, optional.
    @Published var inviteCode = ""
    @Published var confirmingDeletion = false
    /// The Referral Program Terms, accepted before an invite link is issued.
    @Published var acceptedReferralTerms = false

    var hasInviteCode: Bool { !inviteCode.trimmingCharacters(in: .whitespaces).isEmpty }

    var emailLooksValid: Bool {
        let parts = email.trimmingCharacters(in: .whitespaces).split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[1].hasSuffix(".")
    }

    func send(to account: DigisensusAccount) {
        guard emailLooksValid, acceptedTerms else { return }
        UserDefaults.standard.set(email, forKey: "digisensusLastEmail")
        account.register(email: email, referralCode: inviteCode)
    }
}

private struct AISettings: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var account: DigisensusAccount
    @StateObject private var form = SignInForm()

    var body: some View {
        Form {
            Section {
                Picker("Transcribe and summarize with", selection: $library.aiService) {
                    ForEach(AIService.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            switch library.aiService {
            case .digisensus:
                Section("Digisensus account") { DigisensusAccountRows(account: account, form: form) }
                if account.isSignedIn {
                    Section("Invite friends") { InviteRows(account: account, form: form) }
                }
            case .own:
                Section {
                    OwnServiceGrid(library: library)
                } header: {
                    Text("Your AI service")
                } footer: {
                    Text("Any OpenAI-compatible speech-to-text (/v1/audio/transcriptions) and chat (/v1/chat/completions) API. The two can be the same server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .off:
                Section {
                    Text("Recordings stay audio only and nothing leaves this Mac. Pick a service above whenever you want transcripts, summaries and tags.")
                        .foregroundStyle(.secondary)
                }
            }

            if library.aiService != .off {
                Section {
                    Toggle(isOn: $library.autoProcess) {
                        Text("Do it automatically")
                        Text("Transcribe, summarize and tag every new call when it ends.")
                    }
                    Picker("Language", selection: $library.transcription.language) {
                        ForEach(Languages.choices(including: library.transcription.language), id: \.code) {
                            Text($0.name).tag($0.code)
                        }
                    }
                }
            }

            if library.aiService == .digisensus, account.isSignedIn {
                Section {
                    Button("Delete Account…", role: .destructive) { form.confirmingDeletion = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.recordInk)
                        .confirmationDialog("Delete your Digisensus account?", isPresented: $form.confirmingDeletion) {
                            Button("Delete Account", role: .destructive, action: account.deleteAccount)
                        } message: {
                            Text("This removes your email address and signs out every device. Recordings on this Mac are not affected.")
                        }
                }
            }
        }
    }
}

private struct DigisensusAccountRows: View {
    @ObservedObject var account: DigisensusAccount
    @ObservedObject var form: SignInForm

    var body: some View {
        switch account.state {
        case .signedOut, .sending:
            Text("Free daily credit for transcripts and summaries. Sign in with your email, no password.")
                .foregroundStyle(.secondary)
            TextField("Email", text: $form.email, prompt: Text("you@example.com"))
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .onSubmit { form.send(to: account) }
            TextField("Invite code", text: $form.inviteCode, prompt: Text("Optional, from a friend"))
                .autocorrectionDisabled()
            Toggle(isOn: $form.acceptedTerms) {
                Text(form.hasInviteCode ? "I accept the Terms of Service and the Referral Program Terms"
                                        : "I accept the Terms of Service")
                Text("Recordings processed with free daily credit may be used to improve Digisensus models.")
            }
            HStack {
                Link("Terms", destination: DigisensusAccount.termsURL)
                if form.hasInviteCode {
                    Link("Referral Terms", destination: account.referralTermsURL ?? DigisensusAccount.defaultReferralTermsURL)
                }
                Link("Privacy", destination: DigisensusAccount.privacyURL)
                Spacer()
                if account.state == .sending { ProgressView().controlSize(.small) }
                Button("Send Sign-in Link") { form.send(to: account) }
                    .disabled(!form.emailLooksValid || !form.acceptedTerms || account.state == .sending)
                    .keyboardShortcut(.defaultAction)
            }
        case .waiting(let address, let expires):
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check your inbox at \(address)")
                    Text("Open the link in the email and press Confirm, on any device. The app signs in by itself. The link works until \(expires.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Resend") { account.resend(to: address) }
                Button("Cancel", action: account.cancel)
            }
        case .signedIn(let address):
            HStack(spacing: 12) {
                Text(address.prefix(1).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.you)
                    .frame(width: 36, height: 36)
                    .background(Palette.accentTint, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(address).fontWeight(.semibold)
                    Text("Signed in").font(.caption).foregroundStyle(Palette.good)
                }
                Spacer()
                Button("Refresh") { Task { await account.refresh() } }
                Button("Sign Out", action: account.signOut)
            }
            if let balance = account.balance {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Free credit today").font(.caption.weight(.semibold))
                        Spacer()
                        HStack(spacing: 4) {
                            CreditAmount(amount: balance.free, size: 11)
                            Text("left of")
                            CreditAmount(amount: balance.dailyFree, size: 11)
                            if let resets = balance.resetsAt {
                                Text("· renews at \(resets.formatted(date: .omitted, time: .shortened))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    CreditBar(fraction: balance.freeFraction, height: 6)
                    ForEach(Array(balance.referralLots.enumerated()), id: \.offset) { _, lot in
                        HStack(spacing: 4) {
                            Text("Referral credit")
                            CreditAmount(amount: lot.remaining, size: 11)
                            Text("· expires \(lot.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if balance.paid != 0 {
                        HStack(spacing: 4) {
                            Text("Purchased credit")
                            CreditAmount(amount: balance.paid, size: 11)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if !balance.canSpend {
                        Text("Today's credit is used up. Transcripts and summaries resume when it renews.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        if let message = account.message {
            Text(message).foregroundStyle(.secondary)
        }
    }
}

/// Invite a friend: accept the Referral Program Terms, then share the link and follow the
/// friends invited.
private struct InviteRows: View {
    @ObservedObject var account: DigisensusAccount
    @ObservedObject var form: SignInForm

    private var reward: Double { account.referral?.reward ?? account.referralReward }
    private var termsURL: URL {
        account.referral?.termsURL ?? account.referralTermsURL ?? DigisensusAccount.defaultReferralTermsURL
    }

    var body: some View {
        Group {
            if let referral = account.referral, referral.agreed, let code = referral.code {
                LabeledContent {
                    HStack {
                        if let link = referral.link {
                            ShareLink(item: link) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(referral.link?.absoluteString ?? code, forType: .string)
                        }
                    }
                } label: {
                    Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    Text(referral.link?.absoluteString ?? "").textSelection(.enabled)
                }
                if referral.friends.isEmpty {
                    Text("No friends invited yet.").foregroundStyle(.secondary)
                }
                ForEach(referral.friends) { friend in
                    LabeledContent(friend.masked) {
                        Text(Self.statusText(friend.status)).foregroundStyle(Self.statusColor(friend.status))
                    }
                }
                HStack(spacing: 4) {
                    Text("You each get")
                    CreditAmount(amount: reward, size: 11)
                    Text("after your friend's first transcription of a minute or more. Up to \(referral.maxPerYear) friends a year.")
                    Link("Terms", destination: termsURL)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("Invite a friend and you each get")
                    CreditAmount(amount: reward)
                    Text("of credit after their first transcription of a minute or more.")
                }
                Text("Referral credit is valid for 30 days and can't be refunded or paid out. To prevent abuse, invites are checked for fraud using IP addresses and a one-way device ID, and some are reviewed by hand before credit is added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $form.acceptedReferralTerms) {
                    Text("I accept the Referral Program Terms")
                }
                .toggleStyle(.checkbox)
                HStack {
                    Link("Read the Referral Program Terms", destination: termsURL)
                    Spacer()
                    Button("Get My Invite Link", action: account.agreeToReferralTerms)
                        .disabled(!form.acceptedReferralTerms)
                }
            }
        }
        .task { await account.refreshReferral() }
    }

    static func statusText(_ status: String) -> String {
        switch status {
        case "pending_activity": return "Waiting for first transcription"
        case "approved": return "Credit added"
        case "held": return "Being reviewed"
        case "rejected": return "Not eligible"
        case "expired": return "Expired"
        case "revoked": return "Credit removed"
        default: return status
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "approved": return Palette.good
        case "rejected", "revoked": return Palette.recordInk
        default: return .secondary
        }
    }
}

/// Server, key and model for each step. Kept apart because many people run speech and
/// chat models on different servers.
private struct OwnServiceGrid: View {
    @ObservedObject var library: LibraryStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text("Transcription").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Summaries").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            GridRow {
                Text("Server address")
                TextField("Transcription server", text: $library.transcription.server,
                          prompt: Text("https://api.example.com"))
                TextField("Summary server", text: $library.summary.server, prompt: Text("https://api.example.com"))
            }
            GridRow {
                Text("API key")
                SecureField("Transcription API key", text: $library.transcription.apiKey, prompt: Text("Optional"))
                SecureField("Summary API key", text: $library.summary.apiKey, prompt: Text("Optional"))
            }
            GridRow {
                Text("Model")
                TextField("Transcription model", text: $library.transcription.model, prompt: Text("whisper-1"))
                TextField("Summary model", text: $library.summary.model, prompt: Text("Model name"))
            }
            GridRow {
                Button("Test Connection") {
                    library.checkConnection()
                    library.checkSummaryConnection()
                }
                Text(library.connectionStatus ?? "").font(.caption).foregroundStyle(.secondary)
                Text(library.summaryConnectionStatus ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .autocorrectionDisabled()
    }
}

enum Languages {
    struct Choice {
        let code: String
        let name: String
    }

    private static let codes = ["en", "lt", "lv", "et", "pl", "de", "fr", "es", "it", "nl", "sv", "fi", "uk", "ru"]

    /// "Detect automatically", common languages by name, and the saved one if it isn't among them.
    static func choices(including current: String) -> [Choice] {
        var list = codes
        if !current.isEmpty, !list.contains(current) { list.append(current) }
        let named = list.map { Choice(code: $0, name: Locale.current.localizedString(forLanguageCode: $0)?.capitalized ?? $0) }
            .sorted { $0.name < $1.name }
        return [Choice(code: "", name: "Detect automatically")] + named
    }
}

// MARK: Advanced

@MainActor
private final class AgentConnection: ObservableObject {
    enum Client: String, CaseIterable, Identifiable {
        case claude = "Claude Code", codex = "Codex", other = "Other MCP clients", cli = "Command line"
        var id: String { rawValue }
    }

    @Published var client = Client.claude
    @Published var copied = false

    func command(helper: String) -> String {
        switch client {
        case .claude: return "claude mcp add digisensus-recorder -- \"\(helper)\" mcp"
        case .codex: return "codex mcp add digisensus-recorder -- \"\(helper)\" mcp"
        case .other:
            return """
                {"mcpServers": {"digisensus-recorder": {"command": "\(helper)", "args": ["mcp"]}}}
                """
        case .cli: return "\"\(helper)\" status"
        }
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var agents: AgentAccess
    @ObservedObject var updates: UpdateController
    @StateObject private var connection = AgentConnection()

    var body: some View {
        let command = connection.command(helper: AgentAccess.helperURL.path)
        Form {
            Section("AI agents") {
                Toggle(isOn: $agents.isEnabled) {
                    Text("Let AI agents use this app")
                    Text("Claude Code, Codex and other agents on this Mac connect over MCP or the command line. Nothing listens on the network.")
                }
                Toggle("Read recordings, transcripts and notes", isOn: $agents.canReadArchive)
                    .toggleStyle(.checkbox)
                    .disabled(!agents.isEnabled)
                Toggle("Start and stop recordings (agents can never delete)", isOn: $agents.canControlRecording)
                    .toggleStyle(.checkbox)
                    .disabled(!agents.isEnabled)
                HStack(spacing: 10) {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 6))
                        .help(command)
                    Button(connection.copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        connection.copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            connection.copied = false
                        }
                    }
                    Picker("Agent", selection: $connection.client) {
                        ForEach(AgentConnection.Client.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let failure = agents.serverFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if agents.isListening {
                    Label("Accepting agent commands", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.good)
                }
                if !agents.activity.isEmpty {
                    DisclosureGroup("Recent agent activity (\(agents.activity.count))") {
                        ForEach(agents.activity.prefix(15)) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: entry.failure == nil ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(entry.failure == nil ? Color.secondary : Color.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.command).font(.system(.body, design: .monospaced))
                                    if let failure = entry.failure {
                                        Text(failure).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(entry.client) · \(entry.date.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Clear Activity", action: agents.clearActivity)
                    }
                }
            }

            Section("Updates") {
                if updates.isEnabled {
                    Toggle(isOn: $updates.installsAutomatically) {
                        Text("Install updates automatically")
                        Text("Downloads in the background and installs when you're not on a call.")
                    }
                    Toggle(isOn: $updates.includesBetas) {
                        Text("Include beta versions")
                        Text("Get new features earlier, before everyone else.")
                    }
                    LabeledContent {
                        if let pending = updates.pending {
                            Button(pending.isReady ? "Restart to Update" : "Update to \(pending.version)…",
                                   action: updates.installNow)
                        } else {
                            Button("Check Now", action: updates.checkNow).disabled(!updates.canCheck)
                        }
                    } label: {
                        Text(updates.pending.map { "Version \($0.version) is \($0.isReady ? "ready to install" : "available")" }
                            ?? "Digisensus Recorder is up to date")
                        Text(updates.lastCheck.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" }
                            ?? "Not checked yet")
                    }
                } else if AppDistribution.current == .appStore {
                    LabeledContent {
                        Button("Open App Store", action: updates.openAppStore)
                    } label: {
                        Text(updates.isOutdated ? "This version is out of date" : "Updates come from the Mac App Store")
                        Text(updates.isOutdated
                             ? "Update in the App Store to keep using Digisensus transcripts and summaries."
                             : "Turn on automatic updates in App Store › Settings to always have the latest version.")
                    }
                } else {
                    Text("This is a local build, which doesn't update itself. Release builds check for updates at launch and every 24 hours.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent {
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                } label: {
                    Text("Digisensus Recorder ") + Text(AppVersion.version).foregroundColor(.secondary)
                        + Text(" (\(AppVersion.build))").foregroundColor(.secondary)
                }
                LabeledContent("Made by") {
                    Link("Digisensus.com", destination: URL(string: "https://digisensus.com")!)
                }
            }
        }
    }
}

// MARK: License

/// Digisensus Recorder's own license (GPL-3.0 with the attribution terms in NOTICE), then the
/// open source libraries it's built on. This page is the program's Appropriate Legal Notices.
private struct LicenseSettings: View {
    private struct Package: Identifiable {
        let name: String
        let version: String
        let use: String
        let license: String
        let file: String
        var id: String { name }
    }

    private let packages = [
        Package(name: "Opus (libopus)", version: "1.6.1", use: "Audio compression for recordings", license: "BSD",
                file: "libopus-1.6.1.txt"),
        Package(name: "libogg", version: "1.3.6", use: "Ogg file format", license: "BSD", file: "libogg-1.3.6.txt"),
        Package(name: "GRDB.swift", version: "7.11.1", use: "Recording library, transcripts and search",
                license: "MIT", file: "GRDB.swift-7.11.1.txt"),
    ] + Self.updater

    /// The App Store build has no updater of its own.
    #if APP_STORE
    private static let updater: [Package] = []
    #else
    private static let updater = [
        Package(name: "Sparkle", version: "2.10.0", use: "Updates the app over the air", license: "MIT",
                file: "Sparkle-2.10.0.txt"),
    ]
    #endif

    private static let sourceCode = URL(string: "https://github.com/Digisensus/digisensus-recorder")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        (Text("Digisensus Recorder").fontWeight(.semibold)
                            + Text(" " + AppVersion.version).foregroundColor(.secondary))
                        Text("Copyright © 2026 Digisensus.com").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    badge("GPL-3.0")
                    Button("View License") { open("DigisensusRecorder-NOTICE.txt") }
                }
                .padding(.vertical, 2)
                // NOTICE term 1: versions based on this app must keep this attribution and link here,
                // worded "Based on Digisensus Recorder by Digisensus.com".
                LabeledContent("Digisensus Recorder by") {
                    Link("Digisensus.com", destination: URL(string: "https://digisensus.com")!)
                }
                LabeledContent("Source code") {
                    Link("GitHub", destination: Self.sourceCode)
                }
            } header: {
                Text("Digisensus Recorder is free and open source software. You can redistribute and modify it under the GNU General Public License version 3, with an attribution term. It comes with no warranty.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.bottom, 4)
            }

            Section {
                ForEach(packages) { package in
                    HStack(spacing: 14) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.secondary)
                            .frame(width: 36, height: 36)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            (Text(package.name).fontWeight(.semibold) + Text(" " + package.version).foregroundColor(.secondary))
                            Text(package.use).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        badge(package.license)
                        Button("View License") { open(package.file) }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("It's built on these open source projects. Thank you to everyone who maintains them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.bottom, 4)
            } footer: {
                Text("Full license texts are also included in the app bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ license: String) -> some View {
        Text(license)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Palette.good)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Palette.goodTint, in: RoundedRectangle(cornerRadius: 6))
    }

    private func open(_ file: String) {
        guard let folder = Bundle.main.url(forResource: "Licenses", withExtension: nil) else { return }
        let url = folder.appendingPathComponent(file)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: url.path) ? url : folder)
    }
}
