import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, ai, advanced, license

    var title: LocalizedStringResource {
        switch self {
        case .general: return "General"
        case .ai: return "Transcription & AI"
        case .advanced: return "Advanced"
        case .license: return "License"
        }
    }

}

@MainActor
final class AppNavigation: ObservableObject {
    enum DetailTab: CaseIterable, Identifiable {
        case summary, transcript, notes

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .summary: return "Summary"
            case .transcript: return "Transcript"
            case .notes: return "Notes"
            }
        }
    }

    @Published var showingLive = false
    @Published var settingsTab: SettingsTab?
    @Published var detailTab = DetailTab.summary
    @Published var offeringLanguage = false
    var followNewestUntil: Date?
    var didOpen = false
    var openSettings: (SettingsTab) -> Void = { _ in }
}

struct MainView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var navigation: AppNavigation
    let permissions: Permissions
    let agents: AgentAccess
    let updates: UpdateController

    private var selected: Recording? {
        library.recordings.first { $0.id == library.selection }
    }

    var body: some View {
        HSplitView {
            sidebar
            if let tab = navigation.settingsTab {
                SettingsPage(tab: tab, model: model, permissions: permissions, agents: agents,
                             updates: updates, navigation: navigation)
                    .background(Palette.canvas)
            } else {
                calls
            }
        }
        .modifier(DeleteConfirmation(library: library))
        .sheet(isPresented: $navigation.offeringLanguage, onDismiss: { LanguageOffer.markMade() }) {
            LanguageOfferSheet(model: model)
        }
        .frame(minWidth: 1040, minHeight: 640)
        .onAppear {
            library.syncFolder()
            model.refreshDevices()
            if !navigation.didOpen {
                navigation.didOpen = true
                library.showLatestDay()
                if model.isRecording { navigation.showingLive = true }
            }
        }
        .onChange(of: model.isRecording) { _, recording in
            if recording {
                navigation.showingLive = true
            } else if navigation.showingLive {
                navigation.showingLive = false
                navigation.followNewestUntil = Date().addingTimeInterval(60)
            }
        }
        .onChange(of: library.recordings.first?.id) { _, newest in
            guard let until = navigation.followNewestUntil, let newest else { return }
            navigation.followNewestUntil = nil
            guard Date() < until, navigation.settingsTab == nil else { return }
            library.focus(on: newest)
        }
        .onChange(of: library.selection) { _, selection in
            if selection != nil {
                navigation.showingLive = false
                navigation.settingsTab = nil
            }
        }
    }

    private var sidebar: some View {
        Sidebar(model: model, library: library, account: library.account, permissions: permissions,
                navigation: navigation)
            .frame(minWidth: 260, idealWidth: 280, maxWidth: 320, maxHeight: .infinity)
            .background(Palette.sidebar)
    }

    private var calls: some View {
        HSplitView {
            CallList(model: model, library: library, navigation: navigation)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440, maxHeight: .infinity)
            Group {
                if navigation.showingLive, model.isRecording {
                    LiveRecordingView(model: model, library: library)
                } else if let selected {
                    CallDetail(library: library, recording: selected, navigation: navigation)
                        .id(selected.id)
                } else {
                    VStack(spacing: 8) {
                        Text("No call selected").font(.system(size: 15, weight: .semibold))
                        Text("Pick a call from the list.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
        }
    }
}

extension LibraryStore {
    func focus(on id: Int64) {
        guard let recording = recordings.first(where: { $0.id == id }) else { return }
        if !passesFilters(recording) { clearFilters() }
        if listMode == .day { select(day: recording.startedAt) } else { showMonth(containing: recording.startedAt) }
        selection = id
    }
}

private struct DeleteConfirmation: ViewModifier {
    @ObservedObject var library: LibraryStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text("Delete “\(library.pendingDeletion?.heading ?? "")”?"),
            isPresented: Binding(get: { library.pendingDeletion != nil },
                                 set: { if !$0 { library.pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive, action: library.deletePending)
            Button("Cancel", role: .cancel) { library.pendingDeletion = nil }
        } message: {
            if let recording = library.pendingDeletion {
                Text("The audio file from \(recording.startedAt.formatted(date: .abbreviated, time: .shortened)) moves to the Trash, where you can still get it back. Its transcript, summary and notes are deleted for good.")
            }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var account: DigisensusAccount
    @ObservedObject var permissions: Permissions
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                RecordButton(model: model)
                DevicesMenu(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ArchiveCalendar(library: library)
                .padding(10)
                .card()
                .padding(.horizontal, 10)

            ScrollView {
                Filters(library: library)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)

            PermissionStatus(permissions: permissions)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .card(radius: 10)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()
            AccountFooter(library: library, account: account, navigation: navigation)
                .frame(height: 52)
                .padding(.horizontal, 14)
        }
    }
}

struct DevicesMenu: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        Menu {
            Picker("Your microphone", selection: $model.micID) {
                ForEach(model.mics) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            Picker("Other side", selection: $model.source) {
                ForEach(model.apps) { Text($0.name).tag($0.source) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: 12))
                Text(verbatim: "\(model.micName) + \(model.sourceName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(model.isRecording)
        .help(model.isRecording ? "Inputs can be changed after this recording" : "Choose your microphone and the other side")
    }
}

private struct Filters: View {
    @ObservedObject var library: LibraryStore

    private static let order = ["Phone", "FaceTime", "WhatsApp", "Viber", "Telegram", "Signal", "Zoom", "Meet",
                                "Teams", "Slack"]

    private var sources: [(key: String, count: Int)] {
        let counts = library.recordings.reduce(into: [String: Int]()) { $0[$1.sourceKey, default: 0] += 1 }
        return counts.sorted { a, b in
            func rank(_ key: String) -> Int { key == "Manual" ? 999 : Self.order.firstIndex(of: key) ?? 100 }
            return rank(a.key) != rank(b.key) ? rank(a.key) < rank(b.key) : a.key < b.key
        }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FILTER")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Palette.tertiary)
                Spacer()
                if library.isFiltering {
                    Button("Clear", action: library.clearFilters)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.you)
                }
            }
            .frame(height: 22)

            if sources.isEmpty {
                Text("Filters appear once you have calls.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Source").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                    FlowLayout(spacing: 5) {
                        ForEach(sources, id: \.key) { source in
                            FilterChip(isOn: library.sourceFilter.contains(source.key),
                                       toggle: { library.sourceFilter.formSymmetricDifference([source.key]) }) {
                                Text(Recording.sourceTitle(source.key))
                                Text(verbatim: "\(source.count)").fontWeight(.medium).opacity(0.7)
                            }
                        }
                    }
                }
            }

            let tags = library.allTags
            if !tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                    FlowLayout(spacing: 5) {
                        ForEach(tags.prefix(24), id: \.self) { tag in
                            FilterChip(isOn: library.tagFilter.contains(tag),
                                       toggle: { library.tagFilter.formSymmetricDifference([tag]) }) {
                                Circle().fill(TagColor.color(for: tag)).frame(width: 7, height: 7)
                                Text(tag)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct FilterChip<Label: View>: View {
    let isOn: Bool
    let toggle: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) { label }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Palette.onStrong : Palette.ink)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(isOn ? Palette.strong : Palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Palette.strong : Palette.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct PermissionStatus: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(spacing: 0) {
            if permissions.missing.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(Palette.good).frame(width: 8, height: 8)
                    Text("Permissions").frame(maxWidth: .infinity, alignment: .leading)
                    Text("All granted").fontWeight(.semibold).foregroundStyle(Palette.good)
                }
                .frame(height: 26)
            }
            ForEach(permissions.missing) { kind in
                HStack(spacing: 8) {
                    Circle().fill(kind.isRequired ? Palette.record : Palette.tertiary).frame(width: 8, height: 8)
                    Text(kind.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        permissions.request(kind)
                    } label: {
                        HStack(spacing: 4) {
                            Text(kind.isRequired ? "Not allowed · Fix" : "Off · Allow")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(kind.isRequired ? Palette.recordInk : Palette.secondary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(kind.isRequired ? Palette.recordTint : Palette.fill, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open System Settings to allow \(kind.name)")
                }
                .frame(height: 28)
            }
            if permissions.systemAudioRefused {
                Text(Permissions.systemAudioHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .font(.system(size: 12))
    }
}

private struct AccountFooter: View {
    static func creditHelp(_ balance: DigisensusAccount.Balance) -> String {
        let free = DigisensusAccount.credit(balance.free)
        let daily = DigisensusAccount.credit(balance.dailyFree)
        guard balance.referral > 0 else { return String(localized: "\(free) of \(daily) free credit left today") }
        let referral = DigisensusAccount.credit(balance.referral)
        return String(localized: "\(free) of \(daily) free credit left today, plus \(referral) referral credit")
    }

    @ObservedObject var library: LibraryStore
    @ObservedObject var account: DigisensusAccount
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        HStack(spacing: 10) {
            Button {
                navigation.openSettings(.ai)
            } label: {
                HStack(spacing: 10) {
                    badge
                    VStack(alignment: .leading, spacing: 4) { status }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Transcription & AI settings")

            Button {
                navigation.openSettings(.general)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .help("Settings (⌘,)")
        }
    }

    @ViewBuilder private var badge: some View {
        switch (library.aiService, account.state) {
        case (.digisensus, .signedIn(let email)):
            Text(email.prefix(1).uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.you)
                .frame(width: 28, height: 28)
                .background(Palette.accentTint, in: Circle())
        default:
            Image(systemName: library.aiService == .own ? "server.rack" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 28, height: 28)
                .background(Palette.fill, in: Circle())
        }
    }

    @ViewBuilder private var status: some View {
        switch library.aiService {
        case .digisensus:
            if account.isSignedIn, let balance = account.balance {
                Text("Free credit today").font(.system(size: 12, weight: .semibold))
                CreditBar(fraction: balance.freeFraction)
                    .help(Self.creditHelp(balance))
            } else if account.isSignedIn {
                Text("Digisensus").font(.system(size: 12, weight: .semibold))
                Text("Signed in").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            } else {
                Text("Not signed in").font(.system(size: 12, weight: .semibold))
                Text("Sign in for transcripts").font(.system(size: 11)).foregroundStyle(Palette.you)
            }
        case .own:
            Text(AIService.own.label).font(.system(size: 12, weight: .semibold))
            Text(URL(string: library.transcription.server)?.host ?? library.transcription.server)
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .lineLimit(1)
        case .off:
            Text("Transcripts off").font(.system(size: 12, weight: .semibold))
            Text("Set up").font(.system(size: 11)).foregroundStyle(Palette.you)
        }
    }
}
