#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

/// 閱讀器的 stale 綁定清理決策（#3411、#3674）。`Book.preferredNotebookId` 經 CloudKit 鏡射，
/// 清錯會把 nil 同步到所有裝置，因此只有正面證據（本機 tombstone 或已回收的 local-* 占位）才 clear。
/// 「不在本機 live 清單」本身不是刪除證據：另一裝置新建、尚未 reconcile 的 notebook 也會缺席。
/// ReaderNotebookPicker 與 ReaderView 共用同一純決策，避免兩套規則分歧。
struct ReaderNotebookPickerSanitizeTests {
    /// #3674：綁定 N 不在本機 notebook 列（另一裝置新建、尚未 reconcile）且無 tombstone → keep。
    @Test func missingFromLocalListWithoutTombstoneKeepsBinding() {
        #expect(Book.sanitizeAction(
            bound: "N", localNotebookIds: ["A", "B"], tombstonedNotebookIds: []
        ) == .keep)
    }

    /// #3411：列表空 = 尚未 settle → 保留綁定（呼叫端不寫 manifest）。
    @Test func emptyUnsettledListKeepsBindingWithoutClearing() {
        #expect(Book.sanitizeAction(
            bound: "X", localNotebookIds: [], tombstonedNotebookIds: []
        ) == .keep)
    }

    @Test func listContainingBindingKeepsBinding() {
        #expect(Book.sanitizeAction(
            bound: "X", localNotebookIds: ["X", "Y"], tombstonedNotebookIds: []
        ) == .keep)
    }

    /// #3674：本機 tombstone（isSoftDeleted，由 reconcile／刪除寫入）是正面刪除證據 → clear。
    @Test func tombstonedBindingClearsBinding() {
        #expect(Book.sanitizeAction(
            bound: "N", localNotebookIds: ["N", "A"], tombstonedNotebookIds: ["N"]
        ) == .clear)
    }

    /// 其他 notebook 被 tombstone 不影響目前綁定。
    @Test func tombstoneOfOtherNotebookKeepsBinding() {
        #expect(Book.sanitizeAction(
            bound: "N", localNotebookIds: ["N", "A"], tombstonedNotebookIds: ["A"]
        ) == .keep)
    }

    /// 離線占位 local-*（只存在於產生它的裝置，server 永不回報）已被 reconcile 回收 → 永遠無法解析 → clear。
    @Test func reapedLocalOrphanBindingClearsBinding() {
        #expect(Book.sanitizeAction(
            bound: "local-aaaa", localNotebookIds: ["A"], tombstonedNotebookIds: []
        ) == .clear)
    }

    @Test func liveLocalOrphanBindingKeepsBinding() {
        #expect(Book.sanitizeAction(
            bound: "local-aaaa", localNotebookIds: ["local-aaaa"], tombstonedNotebookIds: []
        ) == .keep)
    }

    @Test func unboundBookIsKept() {
        #expect(Book.sanitizeAction(
            bound: nil, localNotebookIds: ["Y"], tombstonedNotebookIds: ["Y"]
        ) == .keep)
        #expect(Book.sanitizeAction(
            bound: nil, localNotebookIds: [], tombstonedNotebookIds: []
        ) == .keep)
    }

    /// #3799（#3674 acceptance 2）：綁定之後才開始的 reconcile 回報 server 不含 N，且本機無 N 列 → clear。
    @Test func reconcileBegunAfterBindingOmittingIdClearsBinding() {
        #expect(Book.sanitizeAction(
            bound: "N", localNotebookIds: ["A", "B"], tombstonedNotebookIds: [],
            omittedByReconcileAfterBinding: true
        ) == .clear)
    }

    /// #3799：綁定之前就開始的 reconcile 可能合法地缺席（另一裝置剛建、尚未進 snapshot）→ keep。
    @Test func reconcileBegunBeforeBindingOmittingIdKeepsBinding() {
        #expect(Book.sanitizeAction(
            bound: "N", localNotebookIds: ["A", "B"], tombstonedNotebookIds: [],
            omittedByReconcileAfterBinding: false
        ) == .keep)
    }

    /// 空列表仍是未 settle（#3411），即使有 reconcile 證據也 keep。
    @Test func emptyUnsettledListKeepsBindingEvenWithReconcileEvidence() {
        #expect(Book.sanitizeAction(
            bound: "N", localNotebookIds: [], tombstonedNotebookIds: [],
            omittedByReconcileAfterBinding: true
        ) == .keep)
    }

    /// 時序契約：只有「觀察綁定在前、reconcile 開始在後」且不含 N 的 reconcile 才算證據。
    @Test func ledgerCountsOnlyReconcilesBegunAfterObservedBinding() {
        let ledger = NotebookReconcileLedger()
        let t0 = Date(timeIntervalSince1970: 1_000)
        ledger.recordReconcile(startedAt: t0.addingTimeInterval(-10), remoteIds: ["A"])
        ledger.observeBinding("N", at: t0)
        #expect(!ledger.omittedAfterBinding("N"))
        ledger.recordReconcile(startedAt: t0.addingTimeInterval(10), remoteIds: ["A", "N"])
        #expect(!ledger.omittedAfterBinding("N"))
        ledger.recordReconcile(startedAt: t0.addingTimeInterval(20), remoteIds: ["A"])
        #expect(ledger.omittedAfterBinding("N"))
    }

    /// 未觀察過的綁定沒有證據（保守 keep）。
    @Test func ledgerReturnsNoEvidenceForUnobservedBinding() {
        let ledger = NotebookReconcileLedger()
        ledger.recordReconcile(startedAt: Date(), remoteIds: [])
        #expect(!ledger.omittedAfterBinding("N"))
    }
}
#endif
