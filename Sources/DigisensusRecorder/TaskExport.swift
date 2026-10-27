import AppKit
import EventKit

enum TaskApp: String, CaseIterable, Identifiable {
    case reminders, things, omniFocus

    static var available: [TaskApp] { allCases.filter(\.isInstalled) }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: return String(localized: "Reminders")
        case .things: return "Things"
        case .omniFocus: return "OmniFocus"
        }
    }

    private var isInstalled: Bool {
        switch self {
        case .reminders: return true
        case .things: return Self.canOpen("things:///")
        case .omniFocus: return Self.canOpen("omnifocus:///")
        }
    }

    private static func canOpen(_ address: String) -> Bool {
        URL(string: address).flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) != nil
    }
}

struct TaskExportNotice: Equatable {
    let text: String
    let isError: Bool
}

enum TaskExportError: LocalizedError {
    case remindersDenied
    case noRemindersList
    case noLink

    var errorDescription: String? {
        switch self {
        case .remindersDenied: return String(localized: "Allow Digisensus Recorder in System Settings › Privacy & Security › Reminders.")
        case .noRemindersList: return String(localized: "Reminders has no default list. Choose one in Reminders › Settings.")
        case .noLink: return String(localized: "These tasks could not be put into a link for that app.")
        }
    }
}

@MainActor
final class TaskExporter {
    private let store = EKEventStore()

    func send(_ actions: [ActionItem], from recording: Recording, to app: TaskApp) async throws {
        let notes = { (action: ActionItem) in action.notes(from: recording) }
        switch app {
        case .reminders:
            try await addReminders(actions, notes: notes)
        case .things:
            try open(actions.thingsLink(notes: notes))
        case .omniFocus:
            try open(actions.omniFocusLink(notes: notes))
        }
    }

    private func addReminders(_ actions: [ActionItem], notes: (ActionItem) -> String) async throws {
        guard await hasRemindersAccess() else { throw TaskExportError.remindersDenied }
        guard let list = store.defaultCalendarForNewReminders() else { throw TaskExportError.noRemindersList }
        do {
            for action in actions {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = action.text
                reminder.notes = notes(action)
                if let due = action.dueDate.flatMap(Agreement.date(day:)) {
                    reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
                }
                try store.save(reminder, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            throw error
        }
    }

    private func hasRemindersAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToReminders()) ?? false
        default: return false
        }
    }

    private func open(_ link: URL?) throws {
        guard let link else { throw TaskExportError.noLink }
        NSWorkspace.shared.open(link)
    }
}

extension ActionItem {
    func notes(from recording: Recording) -> String {
        ([recording.origin] + (due.map { [String(localized: "Due \($0).")] } ?? [])).joined(separator: "\n")
    }
}

extension Array where Element == ActionItem {
    func thingsLink(notes: (ActionItem) -> String) -> URL? {
        let todos: [[String: Any]] = map { action in
            var attributes: [String: Any] = ["title": action.text, "notes": notes(action)]
            attributes["deadline"] = action.dueDate
            return ["type": "to-do", "attributes": attributes]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: todos) else { return nil }
        return URL.link(scheme: "things", host: "", path: "/json", query: ["data": String(decoding: data, as: UTF8.self)])
    }

    func omniFocusLink(notes: (ActionItem) -> String) -> URL? {
        let taskPaper = map { action in
            let due = action.dueDate.map { " @due(\($0))" } ?? ""
            let noteLines = notes(action).split(separator: "\n").map { "\t" + $0 }
            return (["- " + action.text + due] + noteLines).joined(separator: "\n")
        }
        return URL.link(scheme: "omnifocus", host: "", path: "/paste",
                        query: ["target": "inbox", "content": taskPaper.joined(separator: "\n")])
    }
}
