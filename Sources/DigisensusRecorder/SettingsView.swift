import AppKit
import SwiftUI

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

private struct GeneralSettings: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var permissions: Permissions
    @AppStorage("showInDock") private var showInDock = true

    var body: some View {
        Form {
            Section {
                Group {
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
            } header: {
                Text("Recording")
            } footer: {
                if model.isRecording {
                    Text("These can be changed after this recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

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
                                .foregroundStyle(permissions.isGranted(kind) ? Palette.good
                                                 : kind.isRequired ? Palette.recordInk : Palette.tertiary)
                            Text(kind.name)
                        }
                    }
                    Spacer()
                    if let missing = permissions.missing.first(where: \.isRequired) ?? permissions.missing.first {
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

@MainActor
final class SignInForm: ObservableObject {
    @Published var email = UserDefaults.standard.string(forKey: "digisensusLastEmail") ?? ""
    @Published var acceptedTerms = false
    @Published var inviteCode = ""
    @Published var confirmingDeletion = false
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
                OwnServiceSection(library: library, purpose: .transcription, settingsPath: \.transcription)
                OwnServiceSection(library: library, purpose: .summary, settingsPath: \.summary)
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
        if account.isSignedIn {
            TrainingToggle(account: account)
        }
        if let message = account.message {
            Text(message).foregroundStyle(.secondary)
        }
    }
}

struct TrainingToggle: View {
    @ObservedObject var account: DigisensusAccount

    var body: some View {
        Toggle(isOn: Binding(get: { account.trainingEnabled }, set: { account.setTraining(enabled: $0) })) {
            Text("Help improve Digisensus speech recognition")
        }
    }
}

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

private struct OwnServiceSection<Settings: AIServiceSettings>: View {
    @ObservedObject var library: LibraryStore
    let purpose: AIPurpose
    let settingsPath: ReferenceWritableKeyPath<LibraryStore, Settings>
    @StateObject private var catalog = ModelCatalog()
    @State private var committedServer: String?
    @FocusState private var editingServer: Bool

    private static var controlWidth: CGFloat { 300 }

    var body: some View {
        let settings = library[keyPath: settingsPath]
        let preset = settings.servicePreset(for: purpose)
        Section {
            LabeledContent("Service") {
                ServicePicker(purposes: [purpose], selection: preset) { library.choose($0, for: purpose) }
                    .dropdownBox()
                    .frame(width: Self.controlWidth)
            }
            if let fixed = preset.server {
                LabeledContent("Server address") {
                    Text(fixed)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(fixed)
                        .frame(width: Self.controlWidth, alignment: .leading)
                }
            } else {
                LabeledContent {
                    TextField("Server address", text: binding(\.server), prompt: Text(preset.addressPrompt(for: purpose)))
                        .focused($editingServer)
                        .onSubmit(commitServer)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(width: Self.controlWidth)
                } label: {
                    Text("Server address")
                    Text("Include the version path the server documents, usually /v1, as in \(preset.addressPrompt(for: purpose)). "
                         + "An address without a path gets /v1 added.")
                }
            }
            LabeledContent("API key") {
                SecureField("API key", text: binding(\.apiKey), prompt: Text(preset.keyPrompt))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(width: Self.controlWidth)
            }
            LabeledContent {
                ModelChooser(purpose: purpose, preset: preset, catalog: catalog, model: binding(\.model))
                    .frame(width: Self.controlWidth)
            } label: {
                Text(purpose == .transcription ? "ASR model" : "LLM model")
                if let hint = catalog.hint { Text(hint) }
            }
            LabeledContent {
                Button("Test Connection") {
                    commitServer()
                    catalog.reload()
                    if purpose == .transcription { library.checkConnection() } else { library.checkSummaryConnection() }
                }
            } label: {
                Text(status ?? "")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(purpose == .transcription ? "Transcription (speech-to-text)" : "Summaries (LLM)")
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .onAppear { committedServer = settings.server }
        .onChange(of: preset.id) { commitServer() }
        .onChange(of: editingServer) { _, editing in if !editing { commitServer() } }
        .task(id: "\(listedServer(settings, preset))\n\(settings.apiKey)\n\(catalog.reloads)") {
            var listed = settings
            listed.server = listedServer(settings, preset)
            guard await catalog.load(listed, for: purpose) else { return }
            if case .listed(let offered) = catalog.state, !offered.contains(settings.model),
               let suggested = preset.suggestedModel(for: purpose), offered.contains(suggested) {
                library[keyPath: settingsPath].model = suggested
            }
        }
    }

    private func listedServer(_ settings: Settings, _ preset: AIPreset) -> String {
        preset.server == nil ? committedServer ?? settings.server : settings.server
    }

    private func commitServer() {
        let address = URL.withoutCredentials(library[keyPath: settingsPath].server)
        if address != library[keyPath: settingsPath].server { library[keyPath: settingsPath].server = address }
        committedServer = address
    }

    private var status: String? {
        purpose == .transcription ? library.connectionStatus : library.summaryConnectionStatus
    }

    private func binding(_ field: WritableKeyPath<Settings, String>) -> Binding<String> {
        Binding(get: { library[keyPath: settingsPath][keyPath: field] },
                set: { library[keyPath: settingsPath][keyPath: field] = $0 })
    }
}

struct ServicePicker: View {
    let purposes: [AIPurpose]
    let selection: AIPreset
    let choose: (AIPreset) -> Void

    var body: some View {
        let item = { (preset: AIPreset) in PopUpMenu.Entry.item(preset.id, title: preset.name) }
        PopUpMenu(entries: [.header("On this Mac")] + AIPreset.choices(for: purposes, in: .thisMac).map(item)
                      + [.header("Cloud")] + AIPreset.choices(for: purposes, in: .cloud).map(item)
                      + [.separator] + AIPreset.choices(for: purposes, in: .anywhere).map(item),
                  selection: selection.id) { id in
            AIPreset.named(id).map(choose)
        }
    }
}

@MainActor
private final class ModelCatalog: ObservableObject {
    enum State: Equatable {
        case loading, listed([String]), needsKey, unlisted
    }

    @Published private(set) var state = State.loading
    @Published private(set) var reloads = 0
    private var loadedFrom = ""

    var hint: String? {
        switch state {
        case .loading: return "Loading the server's models…"
        case .listed: return nil
        case .needsKey: return "Enter the API key to load the model list."
        case .unlisted: return "This server doesn't list its models. Type the name."
        }
    }

    func reload() { reloads += 1 }

    func load(_ settings: some AIServiceSettings, for purpose: AIPurpose) async -> Bool {
        if loadedFrom != settings.server { state = .loading }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        let answer = await ModelList.fetch(settings, for: purpose)
        guard !Task.isCancelled else { return false }
        loadedFrom = settings.server
        switch answer.status {
        case 200 where !answer.names.isEmpty: state = .listed(ModelList.offered(answer.names, for: purpose))
        case 401, 403: state = .needsKey
        default: state = .unlisted
        }
        return true
    }
}

private struct ModelChooser: View {
    let purpose: AIPurpose
    let preset: AIPreset
    @ObservedObject var catalog: ModelCatalog
    @Binding var model: String

    var body: some View {
        if catalog.state == .unlisted {
            TextField(purpose == .transcription ? "ASR model" : "LLM model", text: $model,
                      prompt: Text(preset.suggestedModel(for: purpose) ?? "Model name"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
        } else {
            PopUpMenu(entries: entries, selection: model) { model = $0 }
                .dropdownBox()
        }
    }

    private var entries: [PopUpMenu.Entry] {
        let offered: [String]
        switch catalog.state {
        case .listed(let names): offered = names
        default: offered = [model, preset.suggestedModel(for: purpose) ?? ""].filter { !$0.isEmpty }.uniqued()
        }
        var entries = offered.map { PopUpMenu.Entry.item($0, title: $0) }
        if model.isEmpty {
            entries.insert(.item("", title: "Choose a model"), at: 0)
        } else if !offered.contains(model) {
            entries.insert(.item(model, title: "\(model) (not offered)"), at: 0)
        }
        return entries
    }
}

private extension View {
    func dropdownBox() -> some View {
        padding(.horizontal, 3).card(radius: 6, border: Palette.tertiary.opacity(0.35))
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

struct PopUpMenu: NSViewRepresentable {
    enum Entry: Equatable {
        case header(String)
        case separator
        case item(String, title: String)
    }

    let entries: [Entry]
    let selection: String
    let choose: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.choose = choose
        button.controlSize = Self.appKitSize(context.environment.controlSize)
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
        if context.coordinator.entries != entries {
            context.coordinator.entries = entries
            let menu = NSMenu()
            for entry in entries {
                switch entry {
                case .header(let title): menu.addItem(.sectionHeader(title: title))
                case .separator: menu.addItem(.separator())
                case .item(let id, let title):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.representedObject = id
                    menu.addItem(item)
                }
            }
            button.menu = menu
        }
        if let item = button.itemArray.first(where: { $0.representedObject as? String == selection }) {
            button.select(item)
        }
    }

    private static func appKitSize(_ size: ControlSize) -> NSControl.ControlSize {
        switch size {
        case .mini: return .mini
        case .small: return .small
        case .large, .extraLarge: return .large
        default: return .regular
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var choose: (String) -> Void = { _ in }
        var entries: [Entry] = []

        @objc func picked(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String { choose(id) }
        }
    }
}

enum Languages {
    struct Choice {
        let code: String
        let name: String
    }

    private static let codes = ["en", "lt", "lv", "et", "pl", "de", "fr", "es", "it", "nl", "sv", "fi", "uk", "ru"]

    static func choices(including current: String) -> [Choice] {
        var list = codes
        if !current.isEmpty, !list.contains(current) { list.append(current) }
        let named = list.map { Choice(code: $0, name: Locale.current.localizedString(forLanguageCode: $0)?.capitalized ?? $0) }
            .sorted { $0.name < $1.name }
        return [Choice(code: "", name: "Detect automatically")] + named
    }
}

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
    @AppStorage(OnboardingFlow.onceMoreKey) private var introOnNextStart = false
    @AppStorage(UsageStatistics.sharingKey) private var sharesUsageStatistics = true

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
                                .disabled(updates.restartWaitsForRecording)
                                .help(updates.restartWaitsForRecording ? "Updates wait until the recording ends" : "")
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

            Section("Privacy") {
                Toggle(isOn: $sharesUsageStatistics) {
                    Text("Share usage statistics")
                    Text("When the app checks for messages, it also sends an identifier derived from this Mac, whether the app just started, the chip type, your language and which AI service you chose. It helps us count how many people use each version. Never your recordings, transcripts, notes or contacts.")
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
                Toggle(isOn: $introOnNextStart) {
                    Text("Show the welcome walkthrough at next start")
                    Text("Once; the box clears itself.")
                }
            }
        }
    }
}

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
