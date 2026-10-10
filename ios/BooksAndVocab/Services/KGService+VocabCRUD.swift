//
//  KGService+VocabCRUD.swift
//  Books & Vocab
//

import Foundation

// MARK: - Models

/// Origin of a vocabulary entry — mirrors backend `VocabSource`
/// (`kg/api_models/common.py`). `type` is `"book"` or `"web"`;
/// `url` is web-only, `chapter` is book-only. iOS captures originate
/// from the reader, so `type` is always `"book"` and `url` is `nil`.
struct KGVocabSource: Codable, Equatable {
    let type: String          // "book" | "web"
    let title: String?
    let url: String?          // web only
    let chapter: String?      // book only

    static func book(title: String, chapter: String? = nil) -> KGVocabSource {
        KGVocabSource(type: "book", title: title, url: nil, chapter: chapter)
    }
}

/// Entry to send to KG server
struct KGVocabEntry: Codable {
    let word: String
    let translation: String
    let context: String
    let root_form: String?
    let source: KGVocabSource?
    /// BCP-47 source language (e.g. "en"). Optional — only encoded when
    /// `KGFeatureFlags.vocabularyLangPayloadEnabled` is on. Backend currently
    /// has `extra='ignore'` so any value would be silently dropped.
    let source_lang: String?
    /// BCP-47 target language (e.g. "zh-Hant"). See source_lang note.
    let target_lang: String?
}

struct KGBatchDeleteResponse: Codable {
    let deleted: Int
    let deleted_words: [String]
    let not_found: [String]
}

struct KGBatchArchiveResponse: Codable {
    let updated: Int
    let updated_words: [String]
    let not_found: [String]
}

/// Narrow capability for the two per-card reader/review preferences. Kept
/// separate from `KGServing` until the shared service protocol is updated so
/// this slice can be tested independently of unrelated service capabilities.
protocol CardPreferenceUpdating: AnyObject {
    func updateCardPreferences(
        word: String,
        readerHidden: Bool?,
        reviewExcluded: Bool?,
        notebookId: String
    ) async throws -> KGCard
}

/// Narrow capability for syncing edited vocabulary content without widening
/// the shared `KGServing` protocol for this bounded change.
protocol VocabularyContentUpdating: AnyObject {
    func updateCardContent(
        word: String,
        translation: String,
        explanation: String?,
        notebookId: String
    ) async throws
}

private struct KGCardPreferencesUpdate: Encodable {
    let reader_hidden: Bool?
    let review_excluded: Bool?
}

struct KGVocabContentUpdate: Encodable, Equatable {
    let meaning: String
    let explanation: String?
}

// MARK: - Vocabulary CRUD

extension KGService: CardPreferenceUpdating, VocabularyContentUpdating {

    func deleteCard(word: String, notebookId: String) async throws {
        try await authenticatedVoid(
            path: "api/vocab/\(word)",
            method: "DELETE",
            queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)]
        )
    }

    func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse {
        try await Self.performChunked(words, send: { chunk in
            let body = try JSONEncoder().encode(["words": chunk])
            return try await self.authenticatedDecode(
                KGBatchDeleteResponse.self,
                path: "api/vocab/batch-delete",
                method: "POST",
                queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)],
                body: body
            )
        }, merge: Self.merged)
    }

    func archiveCard(word: String, archived: Bool, notebookId: String) async throws {
        try await authenticatedVoid(
            path: "api/vocab/\(word)/archive",
            method: "PATCH",
            queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)],
            body: try JSONEncoder().encode(["archived": archived])
        )
    }

    func updateCardPreferences(
        word: String,
        readerHidden: Bool?,
        reviewExcluded: Bool?,
        notebookId: String
    ) async throws -> KGCard {
        precondition(readerHidden != nil || reviewExcluded != nil, "At least one card preference is required")
        return try await authenticatedDecode(
            KGCard.self,
            path: "api/vocab/\(word)/preferences",
            method: "PATCH",
            queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)],
            body: try JSONEncoder().encode(
                KGCardPreferencesUpdate(
                    reader_hidden: readerHidden,
                    review_excluded: reviewExcluded
                )
            )
        )
    }

    static func vocabContentPayload(
        translation: String,
        explanation: String?
    ) -> KGVocabContentUpdate {
        KGVocabContentUpdate(meaning: translation, explanation: explanation)
    }

    func updateCardContent(
        word: String,
        translation: String,
        explanation: String?,
        notebookId: String
    ) async throws {
        try await authenticatedVoid(
            path: "api/vocab/\(word)",
            method: "PATCH",
            queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)],
            body: try JSONEncoder().encode(
                Self.vocabContentPayload(
                    translation: translation,
                    explanation: explanation
                )
            )
        )
    }

    func batchArchiveCards(words: [String], archived: Bool, notebookId: String) async throws -> KGBatchArchiveResponse {
        struct BatchArchiveBody: Encodable {
            let words: [String]
            let archived: Bool
        }
        return try await Self.performChunked(words, send: { chunk in
            let body = try JSONEncoder().encode(BatchArchiveBody(words: chunk, archived: archived))
            return try await self.authenticatedDecode(
                KGBatchArchiveResponse.self,
                path: "api/vocab/batch-archive",
                method: "PATCH",
                queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)],
                body: body
            )
        }, merge: Self.merged)
    }

    /// 後端 `VocabSource.title/chapter` 上限 500（Pydantic `max_length` 以 code point 計）。
    /// 超過會讓整筆 item 被 rejected，故 iOS 端先 trim 再以 unicodeScalars 截斷對齊。
    static let sourceTextMaxScalars = 500

    static func clampedSourceText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > sourceTextMaxScalars else { return trimmed }
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(sourceTextMaxScalars)))
    }

    /// `batchAdd` 的 VocabularyEntry → 線上 payload 映射。
    ///
    /// 抽成 static 純函式讓測試與 production 共用同一份邏輯（比照
    /// `SyncCoordinator.locallyResolvableDeletes` 的 dead-test 防護範式）。
    /// `langPayloadEnabled` 以參數注入：`KGFeatureFlags` 是 compile-time
    /// 常量，無法在測試中翻轉；production call site 用預設值。
    static func vocabPayload(
        for entries: [VocabularyEntry],
        langPayloadEnabled: Bool = KGFeatureFlags.vocabularyLangPayloadEnabled
    ) -> [KGVocabEntry] {
        entries.map { entry in
            // iOS captures always originate from the reader, so the source
            // is a book. `bookTitle` is filled at capture time by
            // `ReaderVocabularyContext` — only omit `source` when it is
            // genuinely empty (e.g. demo / legacy entries).
            let title = clampedSourceText(entry.bookTitle)
            let trimmedChapter = entry.chapterTitle.map(clampedSourceText)
            let chapter = (trimmedChapter?.isEmpty == false) ? trimmedChapter : nil
            // Feature flag: backend doesn't persist source_lang/target_lang yet,
            // so suppress the fields entirely until KGFeatureFlags flips on.
            // Once enabled, fall back to currentSource/Target when the local
            // row predates Phase 5 (sourceLang == nil).
            let sourceLangPayload: String?
            let targetLangPayload: String?
            if langPayloadEnabled {
                sourceLangPayload = entry.sourceLang ?? TranslationLanguage.currentSource.rawValue
                targetLangPayload = entry.targetLang ?? TranslationLanguage.currentTarget.rawValue
            } else {
                sourceLangPayload = nil
                targetLangPayload = nil
            }
            return KGVocabEntry(
                word: entry.word,
                translation: entry.translation,
                context: entry.context,
                root_form: entry.rootForm,
                source: title.isEmpty ? nil : .book(title: title, chapter: chapter),
                source_lang: sourceLangPayload,
                target_lang: targetLangPayload
            )
        }
    }

    func batchAdd(entries: [VocabularyEntry], notebookId: String = "default") async throws -> KGAddResponse {
        let payload = Self.vocabPayload(for: entries)
        return try await Self.performChunked(payload, send: { chunk in
            try await self.authenticatedDecode(
                KGAddResponse.self,
                path: "api/vocab",
                method: "POST",
                queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)],
                body: try JSONEncoder().encode(chunk)
            )
        }, merge: Self.merged)
    }

    // MARK: - Batch chunking (backend caps add/delete/archive at 500 items per request)

    static let maxVocabBatchSize = 500

    /// Sends `items` in <= `maxVocabBatchSize` slices and folds the responses.
    /// Empty input still sends once so legacy behaviour is unchanged.
    static func performChunked<Item, Response>(
        _ items: [Item],
        send: ([Item]) async throws -> Response,
        merge: (Response, Response) -> Response
    ) async throws -> Response {
        guard items.count > maxVocabBatchSize else { return try await send(items) }
        var result: Response?
        for start in stride(from: 0, to: items.count, by: maxVocabBatchSize) {
            let chunk = Array(items[start..<min(start + maxVocabBatchSize, items.count)])
            let response = try await send(chunk)
            result = result.map { merge($0, response) } ?? response
        }
        return result!
    }

    static func merged(_ a: KGAddResponse, _ b: KGAddResponse) -> KGAddResponse {
        KGAddResponse(
            created: a.created + b.created,
            skipped: a.skipped + b.skipped,
            duplicates: a.duplicates + b.duplicates,
            cardIds: a.cardIds.merging(b.cardIds) { _, new in new }
        )
    }

    static func merged(_ a: KGBatchDeleteResponse, _ b: KGBatchDeleteResponse) -> KGBatchDeleteResponse {
        KGBatchDeleteResponse(
            deleted: a.deleted + b.deleted,
            deleted_words: a.deleted_words + b.deleted_words,
            not_found: a.not_found + b.not_found
        )
    }

    static func merged(_ a: KGBatchArchiveResponse, _ b: KGBatchArchiveResponse) -> KGBatchArchiveResponse {
        KGBatchArchiveResponse(
            updated: a.updated + b.updated,
            updated_words: a.updated_words + b.updated_words,
            not_found: a.not_found + b.not_found
        )
    }

    func triggerPipeline(notebookId: String = "default") async throws {
        try await authenticatedVoid(
            path: "api/pipeline",
            method: "POST",
            queryItems: [URLQueryItem(name: "notebook_id", value: notebookId)]
        )
    }
}
