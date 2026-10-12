import Foundation
import Testing
@testable import BooksAndVocab

/// #2550：PATCH `api/vocab/{word}` 的 note 欄位三態。nil＝省略（伺服器值不變）；""＝明確清空；非空＝設定。
/// 後端 `update_vocab_word_content` 以「欄位是否存在」區分未變更與清空，因此省略與 "" 不可混用。
@Suite("KGVocabContentUpdate wire encoding")
struct KGVocabContentUpdateTests {

    private func encodedObject(_ update: KGVocabContentUpdate) throws -> [String: Any] {
        let data = try JSONEncoder().encode(update)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("明確清空以空字串送出，伺服器才會清除既有 note")
    func explicitClearEncodesEmptyString() throws {
        let object = try encodedObject(KGVocabContentUpdate(meaning: "m", explanation: ""))

        #expect(object["meaning"] as? String == "m")
        #expect(object["explanation"] as? String == "")
    }

    @Test("未變更的 note 省略該 key，伺服器保留原 note")
    func unchangedNoteOmitsKey() throws {
        let object = try encodedObject(KGVocabContentUpdate(meaning: "m", explanation: nil))

        #expect(object["meaning"] as? String == "m")
        #expect(!object.keys.contains("explanation"))
    }

    @Test("設定的 note 原樣送出")
    func setNoteEncodesValue() throws {
        let object = try encodedObject(KGVocabContentUpdate(meaning: "m", explanation: "語境解釋"))

        #expect(object["explanation"] as? String == "語境解釋")
    }
}
