#if os(iOS)
import Foundation
import SwiftData
import os

enum VocabularyHighlightSignature {
    /// Stable signature for the effective, notebook-scoped highlight set.
    static func make(entries: [VocabularyEntry], notebookId: String?) -> String {
        let words = entries.lazy
            .filter { entry in
                guard entry.shouldAppearInReader else { return false }
                return notebookId.map { entry.notebookId == $0 } ?? true
            }
            .flatMap { entry -> [String] in
                var forms = Set([entry.word.lowercased()])
                forms.formUnion(entry.inflections.map { $0.lowercased() })
                if let root = entry.rootForm?.lowercased() { forms.insert(root) }
                return Array(forms)
            }
        return ([notebookId ?? "*"] + Set(words).sorted()).joined(separator: "\u{1F}")
    }
}

@MainActor
protocol VocabularyContextStore: VocabularyContextProtocol {
    var vocabulary: [VocabularyEntry] { get }
    var modelContext: ModelContext { get }
    var toastCoordinator: AppToastCoordinator { get }
    var queuedDeleteLogPrefix: String { get }
    var localDeleteLogPrefix: String { get }
    var fetchFailureLogPrefix: String? { get }
}

extension VocabularyContextStore {
    var fetchFailureLogPrefix: String? { nil }

    static func entryMatches(_ entry: VocabularyEntry, wordLower: String) -> Bool {
        let normalized = entry.word.lowercased()
        if normalized == wordLower { return true }
        if entry.rootForm?.lowercased() == wordLower { return true }
        return entry.inflections.contains { $0.lowercased() == wordLower }
    }

    func existingEntry(matching word: String) -> VocabularyEntry? {
        let wordLower = word.lowercased()
        let scope = notebookId
        return vocabulary.first { entry in
            guard entry.notebookId == scope else { return false }
            return Self.entryMatches(entry, wordLower: wordLower)
        }
    }

    func deleteEntry(matching word: String) {
        // Snapshot lookup may miss entries inserted in the same event cycle
        // because saveEntry uses deferSave() and @Query refresh is async.
        let entry = existingEntry(matching: word) ?? fetchEntryFromContext(matching: word)
        guard let entry else { return }

        if entry.isSynced {
            entry.queueDelete()
            AppLog.reader.info("\(queuedDeleteLogPrefix): \(word)")
        } else {
            modelContext.delete(entry)
            AppLog.reader.info("\(localDeleteLogPrefix): \(word)")
        }
        modelContext.safeSaveWithToast(toastCoordinator)
    }

    func restoreExistingEntryForSave(
        matching word: String,
        translation: String,
        rootForm: String?
    ) -> Bool? {
        // The reader snapshots (ReaderView / PDFReaderView) come from a @Query that
        // filters out queued deletes, so the restore target is only reachable
        // through the context (#2105). Missing it would insert a second entry and
        // the next sync would delete the server card and its history.
        guard let existing = existingEntry(matching: word) ?? fetchEntryFromContext(matching: word) else {
            return nil
        }
        if existing.syncAction == .delete {
            existing.restorePendingEntry()
            existing.translation = translation
            if let rootForm { existing.rootForm = rootForm }
            modelContext.safeSaveWithToast(toastCoordinator)
            return true
        }
        return false
    }

    func deferSave() {
        let ctx = modelContext
        let toast = toastCoordinator
        DispatchQueue.main.async {
            ctx.safeSaveWithToast(toast)
        }
    }

    static func lookedUpWords(from vocabulary: [VocabularyEntry], notebookId: String? = nil) -> [String] {
        vocabulary.filter { entry in
            guard entry.shouldAppearInReader else { return false }
            if let notebookId {
                return entry.notebookId == notebookId
            }
            return true
        }.flatMap { entry in
            var all = Set([entry.word.lowercased()] + entry.inflections.map { $0.lowercased() })
            if let root = entry.rootForm?.lowercased() { all.insert(root) }
            return Array(all)
        }
    }

    private func fetchEntryFromContext(matching word: String) -> VocabularyEntry? {
        let nbId = notebookId
        let descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate<VocabularyEntry> { $0.notebookId == nbId }
        )
        let candidates: [VocabularyEntry]
        do {
            candidates = try modelContext.fetch(descriptor)
        } catch {
            if let fetchFailureLogPrefix {
                AppLog.reader.error("\(fetchFailureLogPrefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
        let wordLower = word.lowercased()
        let matches = candidates.filter { Self.entryMatches($0, wordLower: wordLower) }
        // A live entry outranks a queued delete for the same word.
        return matches.first { $0.syncAction != .delete } ?? matches.first
    }
}
#endif
