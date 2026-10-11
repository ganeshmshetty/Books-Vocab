import Testing
import Foundation
@testable import BooksAndVocab

/// #2427: the selection-toolbar trash button must only ask; nothing is queued or
/// saved until the destructive dialog is confirmed.
struct KGVocabBatchDeleteConfirmTests {
    @Test func requestOnlyFlagsPending() {
        var confirmation = BatchDeleteConfirmation()

        confirmation.request(selectionCount: 3)

        #expect(confirmation.isPending)
    }

    @Test func requestWithEmptySelectionDoesNotPrompt() {
        var confirmation = BatchDeleteConfirmation()
        confirmation.request(selectionCount: 0)
        #expect(!confirmation.isPending)
    }

    /// Selection is cleared during dismissal; the dialog title must keep the requested count.
    @Test func requestedCountSnapshotSurvivesSelectionClear() {
        var deletes = 0
        var confirmation = BatchDeleteConfirmation()
        confirmation.request(selectionCount: 3)

        confirmation.confirm(selectionCount: 0) { deletes += 1 }

        #expect(confirmation.requestedCount == 3)
        #expect(deletes == 0)
    }

    @Test func cancelClearsPending() {
        var confirmation = BatchDeleteConfirmation()
        confirmation.request(selectionCount: 2)

        confirmation.cancel()

        #expect(!confirmation.isPending)
    }

    @Test func confirmRunsDeleteExactlyOnceAndClearsPending() {
        var deletes = 0
        var confirmation = BatchDeleteConfirmation()
        confirmation.request(selectionCount: 2)

        confirmation.confirm(selectionCount: 2) { deletes += 1 }

        #expect(deletes == 1)
        #expect(!confirmation.isPending)
    }

    @Test func confirmWithEmptySelectionNeverDeletes() {
        var deletes = 0
        var confirmation = BatchDeleteConfirmation()
        confirmation.request(selectionCount: 2)

        confirmation.confirm(selectionCount: 0) { deletes += 1 }

        #expect(deletes == 0)
        #expect(!confirmation.isPending)
    }

    @Test func titleUsesSingularWordingForOneSelection() {
        #expect(KGVocabCopy.batchDeleteTitle(count: 1, language: .english) == "Delete this word?")
        #expect(KGVocabCopy.batchDeleteTitle(count: 7, language: .english) == "Delete 7 words?")
    }

    @Test func messageNamesTheLossInEnglish() {
        #expect(
            KGVocabCopy.batchDeleteMessage(language: .english)
                == "Their review history and knowledge links will be removed too. This cannot be undone."
        )
    }
}
