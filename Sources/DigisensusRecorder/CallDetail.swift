import SwiftUI

@MainActor
final class RecordingDraft: ObservableObject {
    var shownTitle: String
    @Published var title: String
    @Published var notes: String
    @Published var segments: [TranscriptSegment] = []
    @Published var addingTag = false
    @Published var newTag = ""
    private var pendingSave: Task<Void, Never>?

    init(_ recording: Recording) {
        shownTitle = recording.heading
        title = recording.heading
        notes = recording.notes ?? ""
    }

    func saveSoon(_ save: @escaping () -> Void) {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { save() }
        }
    }
}

struct CallDetail: View {
    @ObservedObject var library: LibraryStore
    let recording: Recording
    @ObservedObject var navigation: AppNavigation
    @StateObject private var draft: RecordingDraft
    @StateObject private var player = PlayerModel()

    init(library: LibraryStore, recording: Recording, navigation: AppNavigation) {
        self.library = library
        self.recording = recording
        self.navigation = navigation
        _draft = StateObject(wrappedValue: RecordingDraft(recording))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            PlayerView(player: player)
            Picker("Show", selection: $navigation.detailTab) {
                ForEach(AppNavigation.DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            draft.segments = library.segments(of: recording)
            player.load(library.url(for: recording))
        }
        .onDisappear {
            save()
            player.unload()
        }
        .onChange(of: library.transcriptRevision) {
            draft.segments = library.segments(of: recording)
        }
        .onChange(of: recording.heading) { _, heading in
            if draft.title == draft.shownTitle {
                draft.title = heading
                draft.shownTitle = heading
            }
        }
        .onChange(of: draft.notes) { draft.saveSoon(save) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(recording.heading == recording.channelName ? "" : recording.channelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { library.reveal(recording) } label: {
                    Image(systemName: "folder").frame(width: 36, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show in Finder")
                .help("Show in Finder")
                Menu {
                    RecordingMenu(library: library, recording: recording)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 32).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
                .help("More actions")
            }
            .font(.system(size: 16))
            .foregroundStyle(Palette.secondary)
            TextField("Name", text: $draft.title, prompt: Text(recording.summaryTopic ?? recording.channelName))
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .onSubmit(save)
                .accessibilityLabel("Call name")
            FlowLayout(spacing: 8) {
                Text(DayText.title(recording.startedAt) + ", " + recording.startedAt.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text(recording.durationShort)
                ForEach(recording.tags, id: \.self) { tag in
                    TagChip(tag: tag, size: 12)
                        .contextMenu {
                            Button("Remove “\(tag)”") { library.removeTag(tag, from: recording) }
                            Button("Show Calls Tagged “\(tag)”") {
                                library.tagFilter = [tag]
                                library.showAll()
                            }
                        }
                }
                Button {
                    draft.newTag = ""
                    draft.addingTag = true
                } label: {
                    Text("+ Tag")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .overlay(Capsule().strokeBorder(Palette.tertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add tag")
                .popover(isPresented: $draft.addingTag, arrowEdge: .bottom) {
                    AddTagPopover(library: library, recording: recording, draft: draft)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder private var tabContent: some View {
        let state = CallState(recording, in: library)
        switch navigation.detailTab {
        case .summary:
            ScrollView {
                if case .summarized = state, let summary = recording.summaryLong {
                    SummaryCard(summary: summary, points: recording.summaryPoints ?? [],
                                error: error(for: \.summaryErrors),
                                redo: library.aiService == .off ? nil : { library.summarize(recording) })
                } else {
                    progressOrOffer(state)
                }
            }
        case .transcript:
            if draft.segments.isEmpty {
                ScrollView { progressOrOffer(state) }
            } else {
                TranscriptView(segments: draft.segments, player: player)
            }
        case .notes:
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.notes)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Notes")
                if draft.notes.isEmpty {
                    Text("Add your own notes about this call…")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .card(radius: 14)
        }
    }

    @ViewBuilder private func progressOrOffer(_ state: CallState) -> some View {
        switch state {
        case .transcribing, .summarizing:
            VStack(alignment: .leading, spacing: 10) {
                Text(state.isTranscribing ? "Transcribing…" : "Summarizing…")
                    .font(.system(size: 14, weight: .semibold))
                ProgressView().progressViewStyle(.linear).tint(Palette.accent)
                Text(state.isTranscribing
                     ? "The transcript, summary and tags appear here in a few minutes; a long call takes longer. You can keep working or quit: the app picks the result up when it is back."
                     : "The summary and tags appear here in a moment.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 14)
        default:
            let hasTranscript = recording.transcriptStatus == .done
            let isOff = library.aiService == .off
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 40, height: 40)
                        .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isOff ? "Transcripts are off" : hasTranscript ? "No summary yet" : "Not transcribed yet")
                            .font(.system(size: 14, weight: .semibold))
                        Text(isOff ? "Choose a service to get transcripts, summaries and tags."
                             : "Get a transcript showing who said what, a short summary and tags.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(isOff ? "Set Up…" : hasTranscript ? "Summarize" : "Transcribe & Summarize") {
                        if isOff {
                            navigation.openSettings(.ai)
                        } else if hasTranscript {
                            library.summarize(recording)
                        } else {
                            library.transcribe(recording, summarizeAfter: true)
                        }
                    }
                    .buttonStyle(StrongButtonStyle(fill: Palette.accent, ink: .white, height: 36))
                }
                if let error = error(for: \.transcriptionErrors) ?? error(for: \.summaryErrors) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.recordInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    private func error(for errors: KeyPath<LibraryStore, [Int64: String]>) -> String? {
        recording.id.flatMap { library[keyPath: errors][$0] }
    }

    private func save() {
        guard let current = library.recordings.first(where: { $0.id == recording.id }) else { return }
        var updated = current
        let typed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != draft.shownTitle {
            updated.title = typed.isEmpty || typed == (current.summaryTopic ?? current.channelName) ? nil : typed
            draft.shownTitle = typed.isEmpty ? current.heading : typed
        }
        updated.notes = draft.notes.isEmpty ? nil : draft.notes
        if updated != current { library.save(updated) }
    }
}

extension CallState {
    var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }
}

private struct SummaryCard: View {
    let summary: String
    let points: [String]
    let error: String?
    let redo: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.accent)
                Text("Summary")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let redo {
                    Button("Redo", action: redo)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.you)
                        .help("Summarize this call again")
                }
            }
            Text(summary)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(Palette.ink.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                            Text(point).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink.opacity(0.85))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.recordInk)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }
}

private struct TranscriptView: View {
    let segments: [TranscriptSegment]
    @ObservedObject var player: PlayerModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(segments) { segment in
                    HStack(alignment: .top, spacing: 14) {
                        Text(RecorderModel.clock(segment.startTime))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Palette.tertiary)
                            .frame(width: 42, alignment: .leading)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(segment.channel == .me ? "You" : "Them")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(segment.channel == .me ? Palette.you : Palette.them)
                            Text(segment.text)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.seek(to: segment.startTime) }
                    .help("Double-click to play from here")
                }
            }
        }
    }
}

private struct AddTagPopover: View {
    @ObservedObject var library: LibraryStore
    let recording: Recording
    @ObservedObject var draft: RecordingDraft

    private var suggestions: [String] {
        let typed = draft.newTag.trimmingCharacters(in: .whitespaces)
        return library.allTags
            .filter { !recording.tags.contains($0) && (typed.isEmpty || $0.localizedCaseInsensitiveContains(typed)) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Tag", text: $draft.newTag, prompt: Text("New or existing tag"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(draft.newTag) }
            if !suggestions.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button { add(tag) } label: { TagChip(tag: tag, size: 12) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func add(_ tag: String) {
        library.addTag(tag, to: recording)
        draft.addingTag = false
    }
}

struct LiveRecordingView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var library: LibraryStore

    private var footnote: String {
        switch library.aiService {
        case .off: return "Audio only. Turn on transcripts in Settings › Transcription & AI."
        case _ where library.autoProcess: return "Transcript, summary and tags are added automatically after you stop."
        default: return "Transcribe it from the call once you stop."
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    PulsingDot(color: Palette.record)
                    Text("Recording · " + (model.autoStarted ? "started automatically" : "started by hand"))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.recordInk)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Palette.recordTint, in: Capsule())
                Text(RecorderModel.clock(model.elapsed))
                    .font(.system(size: 64, weight: .light))
                    .monospacedDigit()
                Text(model.autoStarted
                     ? "\(Recording.channelName(for: model.currentCall?.label)) · stops by itself when the call ends"
                     : "Press Stop or ⌘R when you're done")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                if let message = model.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Palette.recordInk)
                }
            }

            VStack(spacing: 14) {
                side("You", detail: model.micName, ink: Palette.you, wave: Palette.youWave, levels: model.micHistory)
                Divider()
                side("Them", detail: model.sourceName, ink: Palette.them, wave: Palette.themWave, levels: model.appHistory)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .card(radius: 14)

            VStack(alignment: .leading, spacing: 8) {
                Text("Notes").font(.system(size: 15, weight: .bold))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.liveNotes)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Notes")
                    if model.liveNotes.isEmpty {
                        Text("Jot down anything while you talk. Notes are saved with the recording.")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxHeight: .infinity)
            .card(radius: 14)

            Label(footnote, systemImage: "sparkle")
                .font(.system(size: 13))
                .foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func side(_ name: String, detail: String, ink: Color, wave: Color, levels: [Float]) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .bold)).foregroundStyle(ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            LevelBars(levels: levels, color: wave, maxHeight: 34)
                .frame(height: 36)
        }
    }
}
