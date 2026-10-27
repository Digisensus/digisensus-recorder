import AppKit

enum AppLanguage {
    static let codes = [
        "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "id", "it", "ja", "ko",
        "lt", "nl", "pl", "pt-BR", "ru", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]

    static var inUse: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static var chosen: String {
        let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
        return (domain?["AppleLanguages"] as? [String])?.lazy.compactMap(supported).first ?? ""
    }

    static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
    }

    static var speaksSystemLanguage: Bool {
        systemLanguages.first.flatMap(supported) != nil
    }

    static func shown(for choice: String) -> String {
        choice.isEmpty ? systemLanguages.lazy.compactMap(supported).first ?? "en" : choice
    }

    static func supported(_ identifier: String) -> String? {
        if codes.contains(identifier) { return identifier }
        let wanted = Locale.Language(identifier: Locale.Language(identifier: identifier).maximalIdentifier)
        return codes.first { code in
            let candidate = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier)
            return candidate.languageCode == wanted.languageCode && candidate.script == wanted.script
        }
    }

    static var byNativeName: [String] {
        codes.sorted { nativeName($0).localizedStandardCompare(nativeName($1)) == .orderedAscending }
    }

    static func nativeName(_ code: String) -> String {
        if code == "id" { return "Bahasa Indonesia" }
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    static func apply(_ code: String) {
        let defaults = UserDefaults.standard
        LanguageOffer.markMade(in: defaults)
        if code.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: "AppleTextDirection")
        } else {
            defaults.set([code], forKey: "AppleLanguages")
            defaults.set(Locale.Language(identifier: code).characterDirection == .rightToLeft, forKey: "AppleTextDirection")
        }
    }

    @MainActor private static var relaunching = false

    @MainActor static func relaunch() {
        guard !relaunching else { return }
        relaunching = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    relaunching = false
                    Log.write("relaunch failed: \(error)")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

enum LanguageOffer {
    static let key = "languageOffered"

    static func isDue(in defaults: UserDefaults = .standard, chosen: String = AppLanguage.chosen) -> Bool {
        defaults.bool(forKey: OnboardingFlow.doneKey) && !defaults.bool(forKey: key) && chosen.isEmpty
    }

    static func markMade(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}

enum SummaryLanguage {
    static let key = "summaryLanguage"
    static let followsApp = "app"
    static let matchesCall = "call"

    static var chosen: String { UserDefaults.standard.string(forKey: key) ?? followsApp }

    static func rule(for choice: String) -> String {
        let keepEnglish = "Keep the JSON keys, and the values of \"kind\", \"owner\", \"proposed_by\", \"agreed_by\", "
            + "\"weekday\" and \"due_weekday\", in English exactly as specified."
        let appLanguageIsAFallback = AppLanguage.chosen.isEmpty && !AppLanguage.speaksSystemLanguage
        guard choice != matchesCall, choice != followsApp || !appLanguageIsAFallback else {
            return "Write every text value in the language the transcript is mostly in. " + keepEnglish
        }
        let code = choice == followsApp ? AppLanguage.inUse : choice
        return "Write every text value in \(AppLanguage.englishName(code)), whatever language the call is in. " + keepEnglish
    }
}
