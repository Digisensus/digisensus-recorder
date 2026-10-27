import Foundation

enum Owner: String, Codable {
    case you, them, both

    var label: String {
        switch self {
        case .you: return String(localized: "You")
        case .them: return String(localized: "Them")
        case .both: return String(localized: "Both")
        }
    }
}

struct Decision: Codable, Equatable {
    var text: String
    var comment: String?
    var proposedBy: Owner?
    var agreedBy: Owner?
    var topic: String?
    var atSeconds: Double?

    var whoDecided: String {
        switch (proposedBy?.label, agreedBy?.label) {
        case let (proposed?, agreed?): return String(localized: "suggested by \(proposed), agreed by \(agreed)")
        case let (proposed?, nil): return String(localized: "suggested by \(proposed)")
        case let (nil, agreed?): return String(localized: "agreed by \(agreed)")
        case (nil, nil): return ""
        }
    }

    var markdown: String {
        "- " + text + (comment.map { " (\($0))" } ?? "") + (whoDecided.isEmpty ? "" : ", \(whoDecided)")
    }

    var jsonObject: [String: Any] {
        let values: [String: Any?] = ["text": text, "comment": comment, "proposed_by": proposedBy?.rawValue,
                                      "agreed_by": agreedBy?.rawValue, "topic": topic, "at": atSeconds]
        return values.compactMapValues { $0 }
    }
}

struct ActionItem: Codable, Equatable {
    var text: String
    var owner: Owner?
    var due: String?
    var dueDate: String?
    var topic: String?
    var atSeconds: Double?
    var done = false

    var details: String {
        [owner?.label, due].compactMap { $0 }.joined(separator: ", ")
    }

    var markdown: String {
        "- [\(done ? "x" : " ")] " + text + (details.isEmpty ? "" : " (\(details))")
    }

    var jsonObject: [String: Any] {
        let values: [String: Any?] = ["text": text, "owner": owner?.rawValue, "due": due, "due_date": dueDate,
                                      "topic": topic, "at": atSeconds, "done": done]
        return values.compactMapValues { $0 }
    }
}

struct TopicGroup<Item>: Identifiable {
    let id: String
    let topic: String?
    let entries: [(index: Int, item: Item)]

    static func grouping(_ items: [Item], where include: (Item) -> Bool = { _ in true },
                         topic: (Item) -> String?) -> [TopicGroup] {
        let entries = items.enumerated().filter { include($0.element) }.map { (index: $0.offset, item: $0.element) }
        var names: [String: String] = [:]
        var order: [String] = []
        var buckets: [String: [(index: Int, item: Item)]] = [:]
        for entry in entries {
            let name = topic(entry.item)?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = name.lowercased()
            if buckets[key] == nil {
                order.append(key)
                names[key] = name
            }
            buckets[key, default: []].append(entry)
        }
        guard order.count > 1, entries.count >= 6 else { return [TopicGroup(id: "", topic: nil, entries: entries)] }
        return order.map { key in
            let name = names[key] ?? ""
            return TopicGroup(id: key, topic: name.isEmpty ? String(localized: "Other") : name, entries: buckets[key] ?? [])
        }
    }
}
