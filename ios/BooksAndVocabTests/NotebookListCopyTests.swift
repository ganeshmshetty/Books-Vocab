#if os(iOS)
import Testing
@testable import BooksAndVocab

struct NotebookListCopyTests {

    @Test func signedInEmptyState_promotesNotebookCreation() {
        let copy = NotebookListCopy.emptyState(isLoggedIn: true)

        #expect(copy.title == L10n.string("還沒有單字本"))
        #expect(copy.description == L10n.string("建立第一本，開始整理你的單字"))
        #expect(copy.actionTitle == L10n.string("建立第一本單字本"))
        #expect(copy.actionSystemImage == "plus.circle.fill")
    }

    @Test func signedOutEmptyState_promotesLogin() {
        let copy = NotebookListCopy.emptyState(isLoggedIn: false)

        #expect(copy.title == L10n.string("還沒有單字本"))
        #expect(copy.description == L10n.string("登入後自動建立預設單字本"))
        #expect(copy.actionTitle == L10n.string("登入帳號"))
        #expect(copy.actionSystemImage == "person.crop.circle")
    }

    @Test func allWordsExportEmpty_isNotNotebookScoped() {
        #expect(NotebookListCopy.allWordsExportEmpty == L10n.string("所有單字本沒有可匯出的單字"))
        #expect(NotebookListCopy.allWordsExportEmpty != NotebookListCopy.exportEmpty)
    }

    @Test func allWordsExportFailure_emptyMapsToAllWordsCopy() {
        let message = NotebookListCopy.allWordsExportFailureMessage(for: .empty)

        #expect(message == NotebookListCopy.allWordsExportEmpty)
        #expect(message != NotebookListCopy.exportEmpty)
    }

    @Test func allWordsExportFailure_writeFailedMapsToGenericFailure() {
        #expect(NotebookListCopy.allWordsExportFailureMessage(for: .writeFailed) == NotebookListCopy.exportFailure)
    }

    @Test func destructiveAndRetryCopy_stayStable() {
        #expect(NotebookListCopy.deleteTitle == L10n.string("確定要刪除此單字本？"))
        #expect(NotebookListCopy.deleteButtonTitle == L10n.string("刪除"))
        #expect(NotebookListCopy.retryTitle == L10n.string("重試"))
        #expect(NotebookListCopy.reconcileErrorTitle == L10n.string("單字本同步失敗"))
    }
}
#endif
