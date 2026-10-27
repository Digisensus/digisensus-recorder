import AppKit
import EventKit

enum CalendarDestination: String, CaseIterable, Identifiable {
    case thisMac, google, outlook, microsoft365, otherApp

    static let storageKey = "calendarDestination"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .thisMac: return "Calendar on this Mac"
        case .google: return "Google Calendar"
        case .outlook: return "Outlook.com"
        case .microsoft365: return "Outlook (Microsoft 365)"
        case .otherApp: return "Another app (.ics file)"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .thisMac: return "Goes to the default calendar in Calendar, including Google or Exchange accounts added in System Settings › Internet Accounts."
        case .google, .outlook, .microsoft365: return "Opens the event in your browser to check and save."
        case .otherApp: return "Opens the event in the app your Mac uses for calendar files."
        }
    }
}

enum CalendarWriteError: LocalizedError {
    case noDate
    case noDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .noDate: return String(localized: "This agreement has no valid date.")
        case .noDefaultCalendar: return String(localized: "Calendar has no default calendar for new events. Choose one in Calendar › Settings › General.")
        }
    }
}

@MainActor
final class CalendarWriter {
    private let store = EKEventStore()

    func add(_ agreement: Agreement, from recording: Recording, to destination: CalendarDestination) async throws {
        let notes = agreement.notes(from: recording)
        switch destination {
        case .thisMac:
            if await hasWriteAccess() {
                try save(agreement, notes: notes)
            } else {
                try openFile(for: agreement, notes: notes)
            }
        case .otherApp:
            try openFile(for: agreement, notes: notes)
        case .google:
            try open(agreement.googleCalendarLink(notes: notes))
        case .outlook:
            try open(agreement.outlookLink(host: "outlook.live.com", notes: notes))
        case .microsoft365:
            try open(agreement.outlookLink(host: "outlook.office.com", notes: notes))
        }
    }

    private func hasWriteAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .writeOnly, .fullAccess: return true
        case .notDetermined: return (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        default: return false
        }
    }

    private func save(_ agreement: Agreement, notes: String) throws {
        guard let start = agreement.start, let end = agreement.end else { throw CalendarWriteError.noDate }
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarWriteError.noDefaultCalendar }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = agreement.title
        event.notes = notes
        event.isAllDay = agreement.isAllDay
        event.startDate = start
        event.endDate = agreement.isAllDay ? start : end
        event.addAlarm(EKAlarm(relativeOffset: agreement.alarmOffset))
        try store.save(event, span: .thisEvent)
    }

    private func openFile(for agreement: Agreement, notes: String) throws {
        guard let ics = agreement.icsFile(notes: notes) else { throw CalendarWriteError.noDate }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Calendar events", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(agreement.title.safeFileName + ".ics")
        try ics.write(to: file, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(file)
    }

    private func open(_ link: URL?) throws {
        guard let link else { throw CalendarWriteError.noDate }
        NSWorkspace.shared.open(link)
    }
}

extension Agreement {
    var alarmOffset: TimeInterval { isAllDay ? 9 * 3600 : -15 * 60 }

    func notes(from recording: Recording) -> String {
        var lines = [recording.origin]
        if let headline = recording.summaryShort { lines.append(headline) }
        if let quote { lines += ["", "“\(quote)”"] }
        return lines.joined(separator: "\n")
    }

    func googleCalendarLink(notes: String) -> URL? {
        guard let start, let end else { return nil }
        let dates = isAllDay ? [start, end].map(Self.compactDay) : [start, end].map(Self.compactUTC.string(from:))
        return URL.link(host: "calendar.google.com", path: "/calendar/render", query: [
            "action": "TEMPLATE", "text": title, "dates": dates.joined(separator: "/"), "details": notes,
        ])
    }

    func outlookLink(host: String, notes: String) -> URL? {
        guard let start, let end else { return nil }
        let format = isAllDay ? Self.day(of:) : Self.internetUTC.string(from:)
        return URL.link(host: host, path: "/calendar/0/deeplink/compose", query: [
            "path": "/calendar/action/compose", "rru": "addevent", "subject": title, "body": notes,
            "startdt": format(start), "enddt": format(end), "allday": isAllDay ? "true" : "false",
        ])
    }

    func icsFile(notes: String, uid: String = UUID().uuidString, now: Date = Date()) -> String? {
        guard let start, let end else { return nil }
        let times = isAllDay
            ? ["DTSTART;VALUE=DATE:\(Self.compactDay(start))", "DTEND;VALUE=DATE:\(Self.compactDay(end))"]
            : ["DTSTART:\(Self.compactUTC.string(from: start))", "DTEND:\(Self.compactUTC.string(from: end))"]
        let lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Digisensus//Digisensus Recorder//EN", "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT", "UID:\(uid)@recorder.digisensus.com", "DTSTAMP:\(Self.compactUTC.string(from: now))",
        ] + times + [
            "SUMMARY:\(Self.icsEscaped(title))", "DESCRIPTION:\(Self.icsEscaped(notes))",
            "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:\(Self.icsEscaped(title))",
            "TRIGGER:\(alarmOffset < 0 ? "-" : "")PT\(Int(abs(alarmOffset)) / 60)M", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ]
        return lines.map(Self.icsFolded).joined(separator: "\r\n") + "\r\n"
    }

    private static let compactUTC: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return formatter
    }()

    private static let internetUTC = ISO8601DateFormatter()

    private static func compactDay(_ date: Date) -> String {
        day(of: date).replacingOccurrences(of: "-", with: "")
    }

    private static func icsEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func icsFolded(_ line: String) -> String {
        var parts: [String] = []
        var current = ""
        for character in line {
            let limit = parts.isEmpty ? 75 : 74
            if current.utf8.count + String(character).utf8.count > limit {
                parts.append(current)
                current = ""
            }
            current.append(character)
        }
        return (parts + [current]).joined(separator: "\r\n ")
    }
}
