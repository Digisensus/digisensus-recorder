import Foundation
import GRDB

struct Agreement: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    enum Kind: String, Codable { case meeting, deadline, reminder }
    enum Status: String, Codable { case suggested, added, dismissed }

    static let defaultMinutes = 30

    var id: Int64?
    var recordingId: Int64
    var title: String
    var kind: Kind
    var owner: Owner?
    var day: String
    var time: String?
    var durationMinutes: Int?
    var quote: String?
    var atSeconds: Double?
    var status = Status.suggested

    static let databaseTableName = "agreement"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var isAllDay: Bool { time == nil }

    var duplicateKey: String { day + "|" + title.lowercased() }

    var jsonObject: [String: Any] {
        let values: [String: Any?] = [
            "title": title, "kind": kind.rawValue, "owner": owner?.rawValue, "date": day, "time": time,
            "duration_minutes": durationMinutes, "quote": quote, "at": atSeconds, "added_to_calendar": status == .added,
        ]
        return values.compactMapValues { $0 }
    }

    var start: Date? {
        guard let date = Self.date(day: day) else { return nil }
        guard let time, let minutes = Self.minutesIntoDay(time) else { return date }
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date)
    }

    var end: Date? {
        guard let start else { return nil }
        return isAllDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: start)
            : start.addingTimeInterval(Double(durationMinutes ?? Self.defaultMinutes) * 60)
    }

    static func date(day: String) -> Date? {
        let parts = day.split(separator: "-").map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let dayOfMonth = parts[2] else { return nil }
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        guard components.isValidDate(in: .current) else { return nil }
        return Calendar.current.date(from: components)
    }

    static func minutesIntoDay(_ time: String) -> Int? {
        let parts = time.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1],
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func day(of date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func time(of date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func time(minutesIntoDay minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func moving(_ date: Date, toWeekday name: String) -> Date {
        let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        guard let wanted = weekdays.firstIndex(of: name.trimmingCharacters(in: .whitespaces).lowercased()) else { return date }
        let current = (Calendar.current.component(.weekday, from: date) + 5) % 7
        return Calendar.current.date(byAdding: .day, value: wanted - current, to: date) ?? date
    }
}
