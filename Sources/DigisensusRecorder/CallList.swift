import SwiftUI

/// The middle column: search, the selected day's calls or all of them, and the recording
/// in progress at the top.
struct CallList: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var navigation: AppNavigation
    @FocusState private var listFocused: Bool

    private var isSearching: Bool { !library.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Rows in order, with day headers in the all-calls list.
    private var rows: [Row] {
        if isSearching {
            return library.searchResults.map { .call($0.recording, snippet: $0.snippet) }
        }
        var rows: [Row] = []
        var lastDay: Date?
        for recording in library.listedRecordings {
            if library.listMode == .all {
                let day = Calendar.current.startOfDay(for: recording.startedAt)
                if day != lastDay {
                    rows.append(.header(day))
                    lastDay = day
                }
            }
            rows.append(.call(recording, snippet: nil))
        }
        return rows
    }

    private var calls: [Recording] {
        rows.compactMap { if case .call(let recording, _) = $0 { return recording } else { return nil } }
    }

    /// The live card sits on today's list and on the all-calls list.
    private var showsLive: Bool {
        model.isRecording && !isSearching
            && (library.listMode == .all || Calendar.current.isDateInToday(library.selectedDay))
    }

    var body: some View {
        let rows = rows
        let calls = calls
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SearchField(text: $library.searchText)
                if !isSearching {
                    Picker("Show", selection: Binding(get: { library.listMode }, set: { mode in
                        if mode == .day { library.select(day: library.selectedDay) } else { library.showAll() }
                    })) {
                        Text("Selected day").tag(LibraryStore.ListMode.day)
                        Text("All calls").tag(LibraryStore.ListMode.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(calls: calls))
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                    Text(subtitle(calls: calls))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if showsLive {
                            LiveCallCard(model: model, isSelected: navigation.showingLive) {
                                navigation.showingLive = true
                            }
                        }
                        ForEach(rows) { row in
                            switch row {
                            case .header(let day):
                                Text(DayText.title(day).uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(0.4)
                                    .foregroundStyle(Palette.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            case .call(let recording, let snippet):
                                CallRow(library: library, recording: recording, snippet: snippet,
                                        showsDate: isSearching,
                                        isSelected: !navigation.showingLive && library.selection == recording.id) {
                                    library.selection = recording.id
                                    navigation.showingLive = false
                                    listFocused = true
                                }
                                .id(recording.rowID)
                            }
                        }
                        if calls.isEmpty, !showsLive {
                            EmptyList(title: emptyTitle, detail: emptyDetail)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .onChange(of: library.selection) { _, selection in
                    if let selection { withAnimation { proxy.scrollTo(selection) } }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { move(by: 1, in: calls) }
            .onKeyPress(.upArrow) { move(by: -1, in: calls) }
            .onDeleteCommand {
                if let selected = calls.first(where: { $0.id == library.selection }) {
                    library.pendingDeletion = selected
                }
            }
        }
        .background(Palette.canvas)
    }

    private func move(by offset: Int, in calls: [Recording]) -> KeyPress.Result {
        guard !calls.isEmpty else { return .ignored }
        let index = calls.firstIndex { $0.id == library.selection }.map { $0 + offset } ?? 0
        library.selection = calls[min(max(index, 0), calls.count - 1)].id
        navigation.showingLive = false
        return .handled
    }

    private func title(calls: [Recording]) -> String {
        if isSearching { return "Results" }
        if library.listMode == .day { return DayText.title(library.selectedDay) }
        return library.isFiltering ? "Filtered calls" : "All calls"
    }

    private func subtitle(calls: [Recording]) -> String {
        guard !calls.isEmpty else {
            if library.listMode == .day, library.selectedDay > Date(), !isSearching { return "Upcoming" }
            return "No calls"
        }
        let seconds = calls.reduce(0.0) { $0 + ($1.duration ?? 0) }
        return "\(calls.count) call\(calls.count == 1 ? "" : "s") · \(Recording.minutesText(seconds))"
            + (library.isFiltering ? " · filtered" : "")
    }

    private var emptyTitle: String {
        if isSearching { return "Nothing found" }
        if library.isFiltering { return "No calls match these filters" }
        if library.listMode == .all { return "No calls yet" }
        return library.selectedDay > Date() ? "This day hasn’t happened yet" : "No calls on this day"
    }

    private var emptyDetail: String {
        if isSearching { return "Try other words, or clear the filters." }
        if library.isFiltering { return "Clear the filters or pick another day." }
        if library.listMode == .all { return "Calls you record show up here." }
        return "Days with calls have a dot in the calendar."
    }

    private enum Row: Identifiable {
        case header(Date)
        case call(Recording, snippet: String?)

        var id: String {
            switch self {
            case .header(let day): return "day-\(day.timeIntervalSince1970)"
            case .call(let recording, _): return "call-\(recording.rowID)"
            }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            TextField("Search calls and transcripts", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("Search all calls and transcripts")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .card(radius: 8)
    }
}

/// One call as a card: channel, time and length, a one-line summary and its tags.
struct CallRow: View {
    @ObservedObject var library: LibraryStore
    let recording: Recording
    let snippet: String?
    var showsDate = false
    let isSelected: Bool
    let select: () -> Void

    private var when: String {
        let time = recording.startedAt.formatted(date: .omitted, time: .shortened)
        return showsDate ? recording.startedAt.formatted(.dateTime.day().month(.abbreviated)) + ", " + time : time
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ChannelIcon(isPhone: recording.isPhoneCall)
                    Text(recording.titleOrChannel)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(when) · \(recording.durationShort)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                line
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if !recording.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(recording.tags.prefix(3), id: \.self) { TagChip(tag: $0) }
                    }
                }
            }
            .padding(12)
            .background(isSelected ? Palette.card : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Palette.accent : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu { RecordingMenu(library: library, recording: recording) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var line: some View {
        if let snippet {
            Text(Self.highlighted(snippet)).foregroundStyle(Palette.ink.opacity(0.8))
        } else {
            switch CallState(recording, in: library) {
            case .transcribing:
                Text("Transcribing… summary and tags will follow.").italic().foregroundStyle(Palette.tertiary)
            case .summarizing:
                Text("Summarizing…").italic().foregroundStyle(Palette.tertiary)
            case .summarized(let headline):
                Text(headline).foregroundStyle(Palette.ink.opacity(0.8))
            case .transcribed:
                Text("Transcript ready. No summary yet.").italic().foregroundStyle(Palette.tertiary)
            case .failed:
                Text("Transcription failed. Try again from the call.").italic().foregroundStyle(Palette.recordInk)
            case .audioOnly:
                Text("Not transcribed yet.").italic().foregroundStyle(Palette.tertiary)
            }
        }
    }

    /// Search snippets mark the hit «like this»; show it bold instead.
    static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        for part in snippet.split(separator: "«", omittingEmptySubsequences: false) {
            for (index, piece) in part.split(separator: "»", omittingEmptySubsequences: false).enumerated() {
                var run = AttributedString(String(piece))
                if bold, index == 0 { run.font = .system(size: 13, weight: .bold) }
                result += run
            }
            bold = true
        }
        return result
    }
}

/// Where a call is in the transcribe → summarise pipeline.
enum CallState {
    case transcribing, summarizing, summarized(String), transcribed, failed, audioOnly

    @MainActor
    init(_ recording: Recording, in library: LibraryStore) {
        let id = recording.rowID
        if library.transcribing.contains(id) || recording.transcriptStatus == .pending {
            self = .transcribing
        } else if library.summarizing.contains(id) {
            self = .summarizing
        } else if let headline = recording.summaryShort, !headline.isEmpty {
            self = .summarized(headline)
        } else if recording.transcriptStatus == .done {
            self = .transcribed
        } else if recording.transcriptStatus == .failed {
            self = .failed
        } else {
            self = .audioOnly
        }
    }
}

/// The recording in progress, at the top of today's list.
private struct LiveCallCard: View {
    @ObservedObject var model: RecorderModel
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PulsingDot(color: Palette.record, size: 9)
                        .frame(width: 24, height: 24)
                        .background(Palette.recordTint, in: RoundedRectangle(cornerRadius: 6))
                    Text(Recording.channelName(for: model.currentCall?.label))
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Recording · \(RecorderModel.clock(model.elapsed))")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.recordInk)
                }
                Text("Summary and tags are added when the call ends.")
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.record, lineWidth: isSelected ? 2 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// A dot that fades and shrinks in a loop, like the one in the menu bar.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    var period: Double = 1.2

    var body: some View {
        PhaseAnimator([false, true]) { dim in
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(dim ? 0.3 : 1)
                .scaleEffect(dim ? 0.75 : 1)
        } animation: { _ in .easeInOut(duration: period / 2) }
    }
}

private struct EmptyList: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 20))
                .foregroundStyle(Palette.tertiary)
                .frame(width: 48, height: 48)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 14))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 230)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}

struct RecordingMenu: View {
    @ObservedObject var library: LibraryStore
    let recording: Recording
    /// Where the delete confirmation can't show (the menu bar panel): bring up the main window,
    /// which asks, first.
    var openApp: (() -> Void)?

    var body: some View {
        Button("Open in Default App") { library.play(recording) }
        Button("Show in Finder") { library.reveal(recording) }
        Divider()
        Button(recording.transcriptStatus == .done ? "Transcribe Again" : "Transcribe") {
            library.transcribe(recording)
        }
        .disabled(library.aiService == .off)
        Button(recording.summaryLong == nil ? "Summarize" : "Summarize Again") {
            library.summarize(recording)
        }
        .disabled(library.aiService == .off || recording.transcriptStatus != .done)
        Divider()
        Button("Delete…", role: .destructive) {
            if let openApp {
                openApp()
                // Once the window is up to present the confirmation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { library.pendingDeletion = recording }
            } else {
                library.pendingDeletion = recording
            }
        }
    }
}
