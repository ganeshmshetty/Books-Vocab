#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

@Suite(.serialized)
@MainActor
struct LocalizationSemanticKeysTests {
    private let supportedLanguages: [(code: String, language: AppLanguage)] = [
        ("en", .english),
        ("zh-Hant", .traditionalChinese),
        ("zh-Hans", .simplifiedChinese),
        ("ja", .japanese),
        ("ko", .korean)
    ]

    private let semanticKeys = [
        "reader.icloud.syncTimeout",
        "reader.pdf.loading.title",
        "reader.pdf.loading.description",
        "todayReview.completion.nextDue",
        "settings.sync.lastSynced",
        "app.loading.progress"
    ]

    private let settingsPlanHeaderKeys = [
        "功能",
        "Free"
    ]

    private let pluralKeys = [
        "notebook.dueCount",
        "notebook.unlearnedCount",
        "vocab.reviewProgress.percent"
    ]

    @Test
    func semanticKeysResolveInEverySupportedLanguage() throws {
        let store = AppLanguageStore.shared
        defer { store.setLanguage(.system) }

        for (locale, language) in supportedLanguages {
            store.setLanguage(language)
            let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in semanticKeys {
                let value = bundle.localizedString(
                    forKey: key,
                    value: "**missing**",
                    table: "Localizable"
                )
                #expect(value != "**missing**", "missing \(locale) translation for \(key)")
                #expect(value != key, "untranslated \(locale) key for \(key)")
                #expect(L10n.string(key) == value, "runtime bundle mismatch for \(locale) key \(key)")
                if locale == "en" {
                    let hasChinese = value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                    #expect(!hasChinese, "English translation contains CJK for \(key): \(value)")
                }
            }
        }
    }

    @Test
    func pluralKeysRenderEnglishCountContracts() {
        let store = AppLanguageStore.shared
        store.setLanguage(.english)
        defer { store.setLanguage(.system) }

        #expect(L10n.format(pluralKeys[0], Int64(1)) == "1 due")
        #expect(L10n.format(pluralKeys[0], Int64(2)) == "2 due")
        #expect(L10n.format(pluralKeys[1], Int64(1)) == "1 unlearned")
        #expect(L10n.format(pluralKeys[1], Int64(2)) == "2 unlearned")
        #expect(L10n.format(pluralKeys[2], Int64(1)) == "Progress 1%")
        #expect(L10n.format(pluralKeys[2], Int64(2)) == "Progress 2%")
    }

    @Test
    func pluralKeysResolveInEverySupportedLanguage() throws {
        let store = AppLanguageStore.shared
        defer { store.setLanguage(.system) }

        for (locale, language) in supportedLanguages {
            store.setLanguage(language)
            let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let stringsDictURL = URL(fileURLWithPath: path)
                .appendingPathComponent("Localizable.stringsdict")
            let data = try Data(contentsOf: stringsDictURL)
            let root = try #require(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )

            for key in pluralKeys {
                let entry = try #require(root[key] as? [String: Any], "missing \(locale) plural key \(key)")
                #expect(entry["NSStringLocalizedFormatKey"] as? String == "%#@count@")
                let count = try #require(entry["count"] as? [String: Any])
                #expect(count["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType")
                #expect(count["NSStringFormatValueTypeKey"] as? String == "lld")
                let other = try #require(count["other"] as? String)
                #expect(other.contains("%lld"), "missing %lld in \(locale) plural key \(key)")
                let rendered = L10n.format(key, Int64(2))
                #expect(!rendered.isEmpty, "empty runtime plural for \(locale) key \(key)")
                #expect(rendered != key, "untranslated runtime plural for \(locale) key \(key)")
                #expect(rendered.contains("2"), "missing count in \(locale) plural key \(key): \(rendered)")
                if locale == "en" {
                    #expect((count["one"] as? String)?.isEmpty == false)
                }
            }
        }
    }

    @Test
    func settingsPlanHeaderKeysResolveInEverySupportedLanguage() throws {
        let store = AppLanguageStore.shared
        defer { store.setLanguage(.system) }

        for (locale, language) in supportedLanguages {
            store.setLanguage(language)
            let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in settingsPlanHeaderKeys {
                let value = bundle.localizedString(
                    forKey: key,
                    value: "**missing**",
                    table: "Localizable"
                )
                #expect(value != "**missing**", "missing \(locale) translation for settings plan header \(key)")
                #expect(L10n.string(key) == value, "runtime bundle mismatch for \(locale) settings plan header \(key)")
            }
            let free = bundle.localizedString(forKey: "Free", value: "**missing**", table: "Localizable")
            if locale != "en" {
                #expect(free != "Free", "untranslated \(locale) settings plan header Free")
            }
        }
    }
}
#endif
