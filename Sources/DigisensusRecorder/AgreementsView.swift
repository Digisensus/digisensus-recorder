import SwiftUI

struct AgreementsCard: View {
    @ObservedObject var library: LibraryStore
    let recording: Recording
    let agreements: [Agreement]
    let play: (Double) -> Void

    var body: some View {
        SummarySection(symbol: "calendar.badge.plus", title: "Agreed in this call") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(agreements) { agreement in
                    AgreementRow(library: library, recording: recording, agreement: agreement, play: play)
                }
            }
            Text("Suggested by AI from the transcript. Check the date before adding it.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.tertiary)
        }
    }
}

private struct AgreementRow: View {
    @ObservedObject var library: LibraryStore
    let recording: Recording
    let agreement: Agreement
    let play: (Double) -> Void
    @State private var editing = false

    private var isAdding: Bool { agreement.id.map(library.addingToCalendar.contains) ?? false }
    private var error: String? { agreement.id.flatMap { library.agreementErrors[$0] } }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(for: agreement.kind))
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(agreement.title)
                    .font(.system(size: 14, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.when(agreement))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                if let quote = agreement.quote {
                    quoteLine(quote)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.recordInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    @ViewBuilder private func quoteLine(_ quote: String) -> some View {
        let text = Text("“\(quote)”")
            .font(.system(size: 12))
            .italic()
            .foregroundStyle(Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        if let at = agreement.atSeconds {
            Button { play(at) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Palette.tertiary)
                    text
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play from \(RecorderModel.clock(at))")
        } else {
            text
        }
    }

    @ViewBuilder private var actions: some View {
        if agreement.status == .added {
            Label("Added", systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.good)
        } else if isAdding {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 6) {
                Button("Add…") { editing = true }
                    .controlSize(.small)
                    .help("Add to Calendar")
                    .popover(isPresented: $editing, arrowEdge: .bottom) {
                        AgreementEditor(agreement: agreement) { edited, destination in
                            editing = false
                            library.addToCalendar(edited, from: recording, destination: destination)
                        } cancel: {
                            editing = false
                        }
                    }
                Button { library.dismiss(agreement) } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.tertiary)
                .accessibilityLabel("Dismiss")
                .help("Dismiss this suggestion")
            }
        }
    }

    static func symbol(for kind: Agreement.Kind) -> String {
        switch kind {
        case .meeting: return "person.2"
        case .deadline: return "flag"
        case .reminder: return "bell"
        }
    }

    static func when(_ agreement: Agreement) -> String {
        guard let start = agreement.start else { return agreement.day }
        var parts = [start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())]
        if !agreement.isAllDay {
            parts.append(start.formatted(date: .omitted, time: .shortened))
            parts.append(Duration.seconds((agreement.durationMinutes ?? Agreement.defaultMinutes) * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        if let owner = agreement.owner { parts.append(owner.label) }
        return parts.joined(separator: " · ")
    }
}

private struct AgreementEditor: View {
    let agreement: Agreement
    let add: (Agreement, CalendarDestination) -> Void
    let cancel: () -> Void
    @AppStorage(CalendarDestination.storageKey) private var destination = CalendarDestination.thisMac
    @State private var title: String
    @State private var start: Date
    @State private var allDay: Bool
    @State private var minutes: Int

    private static let durations = [15, 30, 45, 60, 90, 120, 180]

    init(agreement: Agreement, add: @escaping (Agreement, CalendarDestination) -> Void, cancel: @escaping () -> Void) {
        self.agreement = agreement
        self.add = add
        self.cancel = cancel
        _title = State(initialValue: agreement.title)
        _start = State(initialValue: agreement.start ?? Date())
        _allDay = State(initialValue: agreement.isAllDay)
        let minutes = agreement.durationMinutes ?? Agreement.defaultMinutes
        _minutes = State(initialValue: Self.durations.min { abs($0 - minutes) < abs($1 - minutes) } ?? Agreement.defaultMinutes)
    }

    private var edited: Agreement {
        var edited = agreement
        edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.day = Agreement.day(of: start)
        edited.time = allDay ? nil : Agreement.time(of: start)
        edited.durationMinutes = allDay ? nil : minutes
        return edited
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to Calendar").font(.system(size: 14, weight: .bold))
            Form {
                Picker("Add to", selection: $destination) {
                    ForEach(CalendarDestination.allCases) { Text($0.title).tag($0) }
                }
                TextField("Title", text: $title)
                DatePicker("Date", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                Toggle("All day", isOn: $allDay)
                if !allDay {
                    Picker("Duration", selection: $minutes) {
                        ForEach(Self.durations, id: \.self) { minutes in
                            Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                                .tag(minutes)
                        }
                    }
                }
            }
            .formStyle(.columns)
            .onChange(of: allDay) { _, allDay in
                let calendar = Calendar.current
                if !allDay, calendar.startOfDay(for: start) == start {
                    start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
                }
            }
            Text(destination.explanation)
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { add(edited, destination) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edited.title.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
