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

    @Test func cancelClearsPendingAndNeverReachesDelete() {
        var confirmation = BatchDeleteConfirmation()
        confirmation.request(selectionCount: 2)

        confirmation.cancel()

        #expect(!confirmation.isPending)
    }

    @Test func confirmRunsDeleteExactlyOnceAndClearsPending() {
        var deletes = 0
        var confirmation = BatchDeleteConfirmation()
        confirmation.request(selectionCount: 2)

        confirmation.confirm { deletes += 1 }

        #expect(deletes == 1)
        #expect(!confirmation.isPending)
    }

    @Test func copyNamesTheCountAndTheLoss() {
        #expect(KGVocabCopy.batchDeleteTitle(count: 7).contains("7"))
        #expect(!KGVocabCopy.batchDeleteMessage.isEmpty)
    }
}
