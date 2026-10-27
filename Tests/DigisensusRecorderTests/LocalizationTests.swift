import Foundation
import Testing
@testable import DigisensusRecorder

struct LocalizationTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    private static func catalog(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: resources.appendingPathComponent(name))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["strings"] as? [String: Any] ?? [:]
    }

    private static func values(_ localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return [value] }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    private static let placeholder = try! Regex("%(?:[0-9]+\\$)?(lld|@|d)")

    private static func placeholders(_ text: String) -> [String] {
        text.matches(of: placeholder).compactMap { $0.output[1].substring.map(String.init) }.sorted()
    }

    private static let translated = AppLanguage.codes.filter { $0 != "en" }

    @Test(arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func everyStringIsTranslatedIntoEveryLanguage(_ file: String) throws {
        let strings = try Self.catalog(file)
        #expect(!strings.isEmpty)
        var missing: [String] = []
        var mismatched: [String] = []
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            let source = Self.values(localizations["en"] as? [String: Any] ?? [:]).first ?? key
            for code in Self.translated {
                let values = Self.values(localizations[code] as? [String: Any] ?? [:])
                if values.isEmpty { missing.append("\(code): \(key)") }
                for value in values where Self.placeholders(value) != Self.placeholders(source) {
                    mismatched.append("\(code): \(key) → \(value)")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.count) missing, e.g. \(missing.prefix(5))")
        #expect(mismatched.isEmpty, "\(mismatched.prefix(5))")
    }
}
