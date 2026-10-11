import Foundation
import Testing
@testable import BooksAndVocab

/// Pins `KGService.vocabPayload(for:langPayloadEnabled:)` — the
/// VocabularyEntry → KGVocabEntry mapping used by `batchAdd`.
///
/// 抽成 static 純函式讓測試與 production 共用同一份映射（比照
/// `SyncCoordinator.locallyResolvableDeletes` / `triggerPipelinesIsolated`
/// 的 dead-test 防護範式）。flag 以參數注入：`KGFeatureFlags` 是
/// compile-time 常量，無法在測試中翻轉，參數化才能覆蓋兩個世界。
///
/// 契約來源：
/// - `docs/reference/sync_lifecycle.md`（add path payload）
/// - backend `kg/api_models/common.py` `VocabSource`（type/title/url/chapter）
/// - 後端目前 `extra='ignore'`：flag off 時 source_lang/target_lang
///   必須整個 key 不出現（不是 null），否則 flag 誤開時無法用 wire 證據區分。
///
/// 讀寫 `TranslationLanguage` 全域語言狀態，故掛在 serialized 的
/// `TranslationLanguageTests` 下（其 `init()` 進入 nil-account namespace），
/// 避免與 account 測試並行互踩（#2117）。
extension TranslationLanguageTests {

    private func makeEntry(
        word: String = "ephemeral",
        bookTitle: String = "Moby Dick",
        chapterTitle: String? = nil
    ) -> VocabularyEntry {
        VocabularyEntry(
            word: word,
            translation: "短暫的",
            context: "an ephemeral moment",
            bookTitle: bookTitle,
            chapterTitle: chapterTitle
        )
    }

    /// Encode a payload entry and return the top-level JSON object keys/values.
    private func encodedObject(_ entry: KGVocabEntry) throws -> [String: Any] {
        let data = try JSONEncoder().encode(entry)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj ?? [:]
    }

    // MARK: - 基本欄位 passthrough

    @Test func maps_core_fields_one_to_one() {
        let entry = makeEntry()
        entry.rootForm = "ephemeral"
        let payload = KGService.vocabPayload(for: [entry], langPayloadEnabled: false)
        #expect(payload.count == 1)
        #expect(payload[0].word == "ephemeral")
        #expect(payload[0].translation == "短暫的")
        #expect(payload[0].context == "an ephemeral moment")
        #expect(payload[0].root_form == "ephemeral")
    }

    // MARK: - feature flag 兩世界：source_lang / target_lang

    /// Flag off（目前 shipping 狀態）：即使 entry 帶有 lang，wire payload
    /// 的 source_lang / target_lang **key 必須完全不出現**。
    @Test func flag_off_suppresses_lang_keys_entirely() throws {
        let entry = makeEntry()
        entry.sourceLang = "en"
        entry.targetLang = "zh-Hant"

        let payload = KGService.vocabPayload(for: [entry], langPayloadEnabled: false)
        #expect(payload[0].source_lang == nil)
        #expect(payload[0].target_lang == nil)

        let obj = try encodedObject(payload[0])
        #expect(obj["source_lang"] == nil, "flag off 時 key 不得出現於 wire payload")
        #expect(obj["target_lang"] == nil, "flag off 時 key 不得出現於 wire payload")
    }

    /// Flag on：entry 自帶 lang 時原樣送出。
    @Test func flag_on_uses_entry_langs() throws {
        let entry = makeEntry()
        entry.sourceLang = "ja"
        entry.targetLang = "ko"

        let payload = KGService.vocabPayload(for: [entry], langPayloadEnabled: true)
        #expect(payload[0].source_lang == "ja")
        #expect(payload[0].target_lang == "ko")

        let obj = try encodedObject(payload[0])
        #expect(obj["source_lang"] as? String == "ja")
        #expect(obj["target_lang"] as? String == "ko")
    }

    /// Flag on + pre-Phase-5 本地列（sourceLang == nil）→ fallback 到
    /// TranslationLanguage.currentSource/Target。顯式設定全域再斷言字面值
    /// （snapshot/restore 比照 VocabularyEntryLangCaptureTests）：若只斷言
    /// 「payload == 當下全域」會是半套套邏輯——實作誤讀其他來源而值恰好
    /// 相同時測試照樣通過。
    @Test func flag_on_falls_back_to_current_languages_for_legacy_rows() {
        let prevSource = TranslationLanguage.currentSource
        let prevTarget = TranslationLanguage.currentTarget
        let prevSourceTs = TranslationLanguage.sourceUpdatedAt
        let prevTargetTs = TranslationLanguage.targetUpdatedAt
        defer {
            TranslationLanguage.restore(
                source: prevSource,
                sourceUpdatedAt: prevSourceTs,
                target: prevTarget,
                targetUpdatedAt: prevTargetTs
            )
        }
        TranslationLanguage.currentSource = .ja
        TranslationLanguage.currentTarget = .zhHant

        let entry = makeEntry()
        entry.sourceLang = nil
        entry.targetLang = nil

        let payload = KGService.vocabPayload(for: [entry], langPayloadEnabled: true)
        #expect(payload[0].source_lang == "ja")
        #expect(payload[0].target_lang == "zh-Hant")
    }

    // MARK: - source（書籍出處）組裝

    @Test func book_title_builds_book_source() {
        let payload = KGService.vocabPayload(
            for: [makeEntry(bookTitle: "Pride and Prejudice")],
            langPayloadEnabled: false
        )
        #expect(payload[0].source?.type == "book")
        #expect(payload[0].source?.title == "Pride and Prejudice")
        #expect(payload[0].source?.url == nil)
    }

    /// 空 / 純空白 bookTitle（demo / legacy entry）→ source 整個省略。
    @Test func blank_title_omits_source() throws {
        for title in ["", "   ", "\n\t "] {
            let payload = KGService.vocabPayload(
                for: [makeEntry(bookTitle: title)],
                langPayloadEnabled: false
            )
            #expect(payload[0].source == nil, "title=\(title.debugDescription) 應省略 source")
            let obj = try encodedObject(payload[0])
            #expect(obj["source"] == nil)
        }
    }

    @Test func title_and_chapter_are_trimmed() {
        let payload = KGService.vocabPayload(
            for: [makeEntry(bookTitle: "  Moby Dick \n", chapterTitle: " Chapter 1 ")],
            langPayloadEnabled: false
        )
        #expect(payload[0].source?.title == "Moby Dick")
        #expect(payload[0].source?.chapter == "Chapter 1")
    }

    /// 純空白 chapter → nil（不送空字串給後端）。
    @Test func blank_chapter_becomes_nil() {
        for chapter in ["", "  ", nil] as [String?] {
            let payload = KGService.vocabPayload(
                for: [makeEntry(chapterTitle: chapter)],
                langPayloadEnabled: false
            )
            #expect(payload[0].source?.chapter == nil)
        }
    }

    /// 後端 `VocabSource.title/chapter` max_length=500 以 code point 計；超長會整筆 rejected。
    @Test func title_and_chapter_are_clamped_to_500_scalars() {
        let long = String(repeating: "a", count: 600)
        let payload = KGService.vocabPayload(
            for: [makeEntry(bookTitle: long, chapterTitle: long)],
            langPayloadEnabled: false
        )
        #expect(payload[0].source?.title?.unicodeScalars.count == 500)
        #expect(payload[0].source?.chapter?.unicodeScalars.count == 500)
    }

    /// 組合字元：grapheme 數遠小於 code point 數，clamp 必須以 unicodeScalars 對齊後端 len()。
    @Test func clamp_counts_unicode_scalars_not_graphemes() {
        let combining = String(repeating: "e\u{301}", count: 300)  // 300 graphemes, 600 scalars
        let payload = KGService.vocabPayload(
            for: [makeEntry(bookTitle: combining)],
            langPayloadEnabled: false
        )
        #expect(payload[0].source?.title?.unicodeScalars.count == 500)
    }

    // MARK: - 批次保序

    /// batchAdd 的 cardIds 回填以 word 為 key，但 payload 仍須維持輸入順序
    /// （後端 dedupe / log triage 依賴穩定順序）。
    @Test func payload_preserves_entry_order() {
        let words = ["alpha", "beta", "gamma"]
        let entries = words.map { makeEntry(word: $0) }
        let payload = KGService.vocabPayload(for: entries, langPayloadEnabled: false)
        #expect(payload.map(\.word) == words)
    }
}
