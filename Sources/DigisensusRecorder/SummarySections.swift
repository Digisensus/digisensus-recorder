import AppKit
import SwiftUI

struct SummarySection<Accessory: View, Content: View>: View {
    let symbol: String
    let title: LocalizedStringResource
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Palette.accent)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }
}

extension SummarySection where Accessory == EmptyView {
    init(symbol: String, title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, title: title, accessory: { EmptyView() }, content: content)
    }
}

struct TimeLink: View {
    let seconds: Double
    let play: (Double) -> Void

    var body: some View {
        Button { play(seconds) } label: {
            HStack(spacing: 3) {
                Image(systemName: "play.fill").font(.system(size: 8))
                Text(RecorderModel.clock(seconds)).monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play from \(RecorderModel.clock(seconds))")
    }
}

struct CopyButton: View {
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(copied ? Palette.good : Palette.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy as a list")
        .help("Copy as a list")
    }
}

private struct TopicHeader: View {
    let topic: String

    var body: some View {
        Text(topic)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Palette.tertiary)
            .padding(.top, 4)
    }
}

struct DecisionsCard: View {
    let decisions: [Decision]
    let play: (Double) -> Void

    var body: some View {
        SummarySection(symbol: "checkmark.seal", title: "Decisions") {
            CopyButton { decisions.map(\.markdown).joined(separator: "\n") }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(TopicGroup.grouping(decisions, topic: \.topic)) { group in
                    if let topic = group.topic { TopicHeader(topic: topic) }
                    ForEach(group.entries, id: \.index) { entry in
                        DecisionRow(decision: entry.item, play: play)
                    }
                }
            }
        }
    }
}

private struct OwnerNote: View {
    enum Role { case proposed, agreed }

    let role: Role
    let owner: Owner

    var body: some View {
        let name = Text(owner.label).fontWeight(.semibold).foregroundStyle(owner.color)
        Group {
            switch role {
            case .proposed: Text("Suggested by \(name)")
            case .agreed: Text("Agreed by \(name)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.tertiary)
    }
}

extension Owner {
    var color: Color {
        switch self {
        case .you: return Palette.you
        case .them: return Palette.them
        case .both: return Palette.ink
        }
    }
}

private struct DecisionRow: View {
    let decision: Decision
    let play: (Double) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.good)
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.text)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let comment = decision.comment {
                    Text(comment)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if decision.proposedBy != nil || decision.agreedBy != nil {
                    HStack(spacing: 10) {
                        if let proposedBy = decision.proposedBy { OwnerNote(role: .proposed, owner: proposedBy) }
                        if let agreedBy = decision.agreedBy { OwnerNote(role: .agreed, owner: agreedBy) }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let at = decision.atSeconds { TimeLink(seconds: at, play: play) }
        }
    }
}

struct ActionsCard: View {
    enum Filter: CaseIterable, Identifiable {
        case all, you, them

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .all: return "All"
            case .you: return "You"
            case .them: return "Them"
            }
        }

        func includes(_ action: ActionItem) -> Bool {
            switch self {
            case .all: return true
            case .you: return action.owner == .you || action.owner == .both
            case .them: return action.owner == .them || action.owner == .both
            }
        }
    }

    let actions: [ActionItem]
    let notice: TaskExportNotice?
    let setDone: (Int, Bool) -> Void
    let send: ([ActionItem], TaskApp) -> Void
    let play: (Double) -> Void
    @State private var filter = Filter.all

    private var isSplitBetweenSides: Bool {
        actions.contains { $0.owner == .you } && actions.contains { $0.owner == .them }
    }

    private var shownFilter: Filter { isSplitBetweenSides ? filter : .all }

    private var shown: [ActionItem] { actions.filter(shownFilter.includes) }

    var body: some View {
        SummarySection(symbol: "checklist", title: "Action items") {
            Text("\(actions.filter(\.done).count) of \(actions.count) done")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiary)
            SendTasksMenu(open: shown.filter { !$0.done }, list: shown.map(\.markdown).joined(separator: "\n"), send: send)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if isSplitBetweenSides {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                ForEach(TopicGroup.grouping(actions, where: shownFilter.includes, topic: \.topic)) { group in
                    if let topic = group.topic { TopicHeader(topic: topic) }
                    ForEach(group.entries, id: \.index) { entry in
                        ActionRow(action: entry.item, setDone: { setDone(entry.index, $0) }, play: play)
                            .contextMenu {
                                ForEach(TaskApp.available) { app in
                                    Button("Add to \(app.title)") { send([entry.item], app) }
                                }
                            }
                    }
                }
                if let notice {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(notice.isError ? Palette.recordInk : Palette.good)
                }
            }
        }
    }
}

private struct SendTasksMenu: View {
    let open: [ActionItem]
    let list: String
    let send: ([ActionItem], TaskApp) -> Void

    var body: some View {
        Menu {
            Section("\(open.count) open tasks") {
                ForEach(TaskApp.available) { app in
                    Button("Add to \(app.title)") { send(open, app) }
                        .disabled(open.isEmpty)
                }
            }
            Button("Copy as List") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(list, forType: .string)
            }
            ShareLink("Share…", item: list)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12))
                .foregroundStyle(Palette.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Send tasks")
        .help("Send the open tasks to a to-do app, copy or share them")
    }
}

private struct ActionRow: View {
    let action: ActionItem
    let setDone: (Bool) -> Void
    let play: (Double) -> Void

    private var due: String? {
        action.due ?? action.dueDate.flatMap(Agreement.date(day:))?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { setDone(!action.done) } label: {
                Image(systemName: action.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(action.done ? Palette.good : Palette.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(action.done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 3) {
                Text(action.text)
                    .font(.system(size: 14))
                    .strikethrough(action.done)
                    .foregroundStyle(action.done ? Palette.tertiary : Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if action.owner != nil || due != nil {
                    HStack(spacing: 6) {
                        if let owner = action.owner {
                            Text(owner.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(owner.color)
                        }
                        if let due {
                            Label(due, systemImage: "calendar")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let at = action.atSeconds { TimeLink(seconds: at, play: play) }
        }
    }
}
