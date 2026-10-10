#if DEBUG
import Foundation
import Testing
@testable import BooksAndVocab

@Suite(.serialized)
struct ReaderSettingsFixtureTests {
    @Test func marketingDemoReplaysReaderPreferenceOverlayOnBothStores() throws {
        let document = try FixtureDatasetStore.decode(Self.marketingDemoData)
        let userDefaults = document.preferences.userDefaults
        let ubiquitous = document.preferences.ubiquitousKeyValueStore

        #expect(userDefaults["reader_settings_font"] == .string("Mono"))
        #expect(userDefaults["reader_settings_fontSize"] == .double(1.25))
        #expect(userDefaults["reader_settings_lineHeight"] == .double(2.1))
        #expect(userDefaults["reader_settings_scrollMode"] == .bool(true))
        #expect(userDefaults["reader_settings_underlineOpacity"] == .double(0.60))
        #expect(userDefaults["vocab_highlight_colorPreset"] == .string("rose"))
        #expect(userDefaults["vocab_highlight_opacity"] == .double(0.60))
        #expect(userDefaults["reader_settings_showHitTestingDebug"] == .bool(false))

        for key in [
            "reader_settings_font",
            "reader_settings_fontSize",
            "reader_settings_lineHeight",
            "reader_settings_scrollMode",
            "reader_settings_underlineOpacity",
            "vocab_highlight_colorPreset",
            "vocab_highlight_opacity",
        ] {
            #expect(ubiquitous[key] == userDefaults[key], "Reader preference (key) must replay identically")
        }
    }

    @Test func liveReaderSettingsCanReloadAnOverlayWrittenAfterInitialization() {
        let defaults = UserDefaults(suiteName: "test.reader-settings.\(UUID().uuidString)")!
        let cloud = ReaderSettingsFixtureCloudStore()
        defaults.set(1.5, forKey: "reader_settings_lineHeight")
        cloud.set(1.5, forKey: "reader_settings_lineHeight")

        let settings = ReaderSettings(defaults: defaults, cloud: cloud)
        #expect(settings.lineHeight == 1.5)

        // UI World overlays can arrive after the global instance was already
        // hydrated. Persistence alone must not leave the live SwiftUI binding
        // on the previous value.
        defaults.set(2.1, forKey: "reader_settings_lineHeight")
        cloud.set(2.1, forKey: "reader_settings_lineHeight")
        settings.reloadFromPersistence()

        #expect(settings.lineHeight == 2.1)
    }

    @Test func letterSpacingPersistsAcrossBothStoresAndFeedsReadiumPreferences() {
        let defaults = UserDefaults(suiteName: "test.reader-settings-letter-spacing.\(UUID().uuidString)")!
        let cloud = ReaderSettingsFixtureCloudStore()
        let settings = ReaderSettings(defaults: defaults, cloud: cloud)

        settings.letterSpacing = 0.4

        #expect(defaults.double(forKey: "reader_settings_letterSpacing") == 0.4)
        #expect(cloud.double(forKey: "reader_settings_letterSpacing") == 0.4)
        #expect(
            settings.viewConfiguration(systemColorScheme: .light).epubPreferences.letterSpacing == 0.4
        )

        let restored = ReaderSettings(defaults: defaults, cloud: cloud)
        #expect(restored.letterSpacing == 0.4)
        #expect(
            restored.viewConfiguration(systemColorScheme: .light).epubPreferences.letterSpacing == 0.4
        )
    }

    @Test func customHighlightSRGBRoundTripsThroughBothPreferenceStores() {
        let defaults = UserDefaults(suiteName: "test.reader-settings-custom.\(UUID().uuidString)")!
        let cloud = ReaderSettingsFixtureCloudStore()
        let expected = VocabHighlightSRGB(red: 0.1, green: 0.5, blue: 0.9)

        let settings = ReaderSettings(defaults: defaults, cloud: cloud)
        settings.vocabHighlightCustomSRGB = expected
        settings.vocabHighlightColorPreset = .custom

        #expect(defaults.double(forKey: "vocab_highlight_custom_red") == expected.red)
        #expect(defaults.double(forKey: "vocab_highlight_custom_green") == expected.green)
        #expect(defaults.double(forKey: "vocab_highlight_custom_blue") == expected.blue)
        #expect(cloud.double(forKey: "vocab_highlight_custom_red") == expected.red)
        #expect(cloud.double(forKey: "vocab_highlight_custom_green") == expected.green)
        #expect(cloud.double(forKey: "vocab_highlight_custom_blue") == expected.blue)

        let restored = ReaderSettings(defaults: defaults, cloud: cloud)
        #expect(restored.vocabHighlightColorPreset == .custom)
        #expect(restored.vocabHighlightCustomSRGB == expected)
        #expect(restored.vocabHighlightPreferences.customSRGB == expected)
    }

    private static var marketingDemoData: Data {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // BooksAndVocabTests
                .deletingLastPathComponent() // ios
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("ops/fixtures/ui_worlds/marketing_demo.json")
            return try Data(contentsOf: url)
        }
    }
}

private final class ReaderSettingsFixtureCloudStore: CloudKeyValueStore {
    private var doubles: [String: Double] = [:]
    private var strings: [String: String] = [:]

    func double(forKey key: String) -> Double? { doubles[key] }
    func set(_ value: Double, forKey key: String) { doubles[key] = value }
    func string(forKey key: String) -> String? { strings[key] }
    func set(_ value: String, forKey key: String) { strings[key] = value }
    func removeObject(forKey key: String) {
        doubles[key] = nil
        strings[key] = nil
    }
    func allKeys() -> [String] { Array(doubles.keys) + Array(strings.keys) }
}
#endif
