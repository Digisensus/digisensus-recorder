import Foundation
import Testing
@testable import DigisensusRecorder

struct AppLanguageTests {
    @Test func offersTwentyFiveLanguagesWithTheirOwnNames() {
        #expect(AppLanguage.codes.count == 25 && Set(AppLanguage.codes).count == 25)
        #expect(AppLanguage.nativeName("lt") == "Lietuvių")
        #expect(AppLanguage.nativeName("de") == "Deutsch")
        #expect(AppLanguage.nativeName("id") == "Bahasa Indonesia")
        #expect(AppLanguage.englishName("zh-Hans") == "Chinese, Simplified")
        #expect(AppLanguage.englishName("pt-BR") == "Portuguese (Brazil)")
    }

    @Test func macOSLanguagesMapToTheClosestOneTheAppHas() {
        #expect(AppLanguage.supported("lt") == "lt")
        #expect(AppLanguage.supported("en-GB") == "en")
        #expect(AppLanguage.supported("zh-TW") == "zh-Hant")
        #expect(AppLanguage.supported("zh-Hans-CN") == "zh-Hans")
        #expect(AppLanguage.supported("pt-PT") == "pt-BR")
        #expect(AppLanguage.supported("fi") == nil)
    }

    @Test func summaryRuleNamesTheLanguageOrFollowsTheCall() {
        let lithuanian = SummaryLanguage.rule(for: "lt")
        #expect(lithuanian.hasPrefix("Write every text value in Lithuanian, whatever language the call is in."))
        #expect(lithuanian.contains("\"owner\"") && lithuanian.contains("in English exactly as specified"))
        #expect(SummaryLanguage.rule(for: SummaryLanguage.matchesCall).hasPrefix("Write every text value in the language the transcript is mostly in."))
    }

    @Test func languageIsOfferedOnceToPeopleWhoSetUpAnEarlierVersion() throws {
        let name = "LanguageOfferTests"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!LanguageOffer.isDue(in: defaults, chosen: ""))
        defaults.set(true, forKey: OnboardingFlow.doneKey)
        #expect(LanguageOffer.isDue(in: defaults, chosen: ""))
        #expect(!LanguageOffer.isDue(in: defaults, chosen: "lt"))
        LanguageOffer.markMade(in: defaults)
        #expect(!LanguageOffer.isDue(in: defaults, chosen: ""))
    }
}
