import Foundation
import Testing
@testable import BooksAndVocab

// Tests for the unified top-pill notification system (#2047):
// AppToastItem model, the pure AppToastQueue state machine, and the
// AppToastCoordinator timing wrapper around it.
//
// Contract under test (docs/sop/ui-design.md「暫時性提示」):
// - same event (same `key`) → replace in place, never stack a duplicate;
// - different events → queue, at most `AppToastQueue.capacity` (2) held in total
//   (one visible + one waiting); overflow keeps the more severe notice;
// - a queued pill only enters after the previous one has left (handoff gap),
//   so two pills never swap content in place.
//
// Trade-offs:
// - AppToast / ToastOverlayModifier are SwiftUI Views with no extractable pure
//   state seam, so they are not unit-tested here; the testable seams are the
//   value types and the @Observable coordinator.
// - Queue semantics are pinned on the pure `AppToastQueue` (deterministic, no
//   clock). Auto-dismiss and handoff timing run on an injected
//   `ManualToastScheduler`: tests advance fake time to exactly the deadline
//   instead of sleeping against real timers (#2118). The production
//   `AppToastTaskScheduler` is pinned separately on its own contract. The
//   coordinator schedules auto-dismiss regardless of VoiceOver (announce is a
//   side effect only), so these assertions hold on any simulator configuration.

@Suite("ToastNotification")
@MainActor
struct ToastNotificationTests {

    // MARK: - AppToastItem model

    @Test func itemDefaultImagePerStyle() {
        #expect(AppToastItem(message: "a", style: .success).systemImage == "checkmark")
        #expect(AppToastItem(message: "a", style: .info).systemImage == "info.circle")
        #expect(AppToastItem(message: "a", style: .warning).systemImage == "exclamationmark.triangle")
        #expect(AppToastItem(message: "a", style: .error).systemImage == "xmark.circle")
    }

    @Test func itemCustomImageOverridesDefault() {
        let item = AppToastItem(message: "a", systemImage: "star", style: .success)
        #expect(item.systemImage == "star")
    }

    @Test func itemDurationPerStyle() {
        #expect(AppToastItem(message: "a", style: .success).duration == 2.5)
        #expect(AppToastItem(message: "a", style: .info).duration == 2.5)
        #expect(AppToastItem(message: "a", style: .warning).duration == 4.0)
        #expect(AppToastItem(message: "a", style: .error).duration == 4.0)
    }

    @Test func itemIdentityIsUnique() {
        let a = AppToastItem(message: "same", style: .info)
        let b = AppToastItem(message: "same", style: .info)
        // Distinct UUID → distinct identity and inequality even with same payload.
        #expect(a.id != b.id)
        #expect(a != b)
    }

    @Test func itemDefaultKeyIdentifiesEventByStyleAndMessage() {
        let a = AppToastItem(message: "已複製", style: .success)
        let b = AppToastItem(message: "已複製", style: .success)
        let otherStyle = AppToastItem(message: "已複製", style: .info)
        let otherMessage = AppToastItem(message: "已刪除", style: .success)
        #expect(a.key == b.key)
        #expect(a.key != otherStyle.key)
        #expect(a.key != otherMessage.key)
    }

    @Test func itemExplicitKeyGroupsChangingMessagesIntoOneEvent() {
        let first = AppToastItem(message: "已匯入 1 本", style: .success, key: "bookshelf.import")
        let second = AppToastItem(message: "已匯入 2 本", style: .success, key: "bookshelf.import")
        #expect(first.key == second.key)
    }

    @Test func styleSeverityOrdersErrorAboveWarningAboveRoutine() {
        #expect(AppToastItem.Style.error.severity > AppToastItem.Style.warning.severity)
        #expect(AppToastItem.Style.warning.severity > AppToastItem.Style.info.severity)
        #expect(AppToastItem.Style.info.severity == AppToastItem.Style.success.severity)
    }

    // MARK: - Copy budget (single line, no wrapping)

    @Test func displayWidthCountsWideScriptsAsTwoColumns() {
        #expect(AppToastItem.displayWidth(of: "Copied") == 6)
        #expect(AppToastItem.displayWidth(of: "已複製") == 6)
        #expect(AppToastItem.displayWidth(of: "已匯入 3 本") == 11)
        #expect(AppToastItem.displayWidth(of: "コピー") == 6)
        #expect(AppToastItem.displayWidth(of: "복사됨") == 6)
    }

    @Test func copyBudgetIsTwentyWideOrFortyNarrowCharacters() {
        #expect(AppToastItem.copyBudgetColumns == 40)
        #expect(!AppToastItem.exceedsCopyBudget(String(repeating: "字", count: 20)))
        #expect(AppToastItem.exceedsCopyBudget(String(repeating: "字", count: 21)))
        #expect(!AppToastItem.exceedsCopyBudget(String(repeating: "a", count: 40)))
        #expect(AppToastItem.exceedsCopyBudget(String(repeating: "a", count: 41)))
    }

    // MARK: - AppToastQueue: present / replace

    @Test func queueReceiveIntoEmptyPresents() {
        var queue = AppToastQueue()
        let item = AppToastItem(message: "hello", style: .info)
        #expect(queue.receive(item) == .presented)
        #expect(queue.current == item)
        #expect(queue.pending.isEmpty)
    }

    @Test func queueSameEventReplacesCurrentInPlace() {
        var queue = AppToastQueue()
        let first = AppToastItem(message: "已匯入 1 本", style: .success, key: "import")
        let second = AppToastItem(message: "已匯入 2 本", style: .success, key: "import")
        _ = queue.receive(first)
        #expect(queue.receive(second) == .replacedCurrent)
        #expect(queue.current == second)
        #expect(queue.pending.isEmpty)
    }

    @Test func queueIdenticalNoticeCollapsesIntoCurrent() {
        var queue = AppToastQueue()
        _ = queue.receive(AppToastItem(message: "dup", style: .info))
        for _ in 0..<5 {
            #expect(queue.receive(AppToastItem(message: "dup", style: .info)) == .replacedCurrent)
        }
        #expect(queue.pending.isEmpty)
        #expect(queue.current?.message == "dup")
    }

    @Test func queueDifferentEventWaitsBehindCurrent() {
        var queue = AppToastQueue()
        let first = AppToastItem(message: "first", style: .info)
        let second = AppToastItem(message: "second", style: .warning)
        _ = queue.receive(first)
        #expect(queue.receive(second) == .queued(evicted: nil))
        #expect(queue.current == first)
        #expect(queue.pending == [second])
    }

    @Test func queueSameEventReplacesWaitingItem() {
        var queue = AppToastQueue()
        let visible = AppToastItem(message: "visible", style: .info)
        let waiting = AppToastItem(message: "同步中 1/3", style: .info, key: "sync")
        let update = AppToastItem(message: "同步中 2/3", style: .info, key: "sync")
        _ = queue.receive(visible)
        _ = queue.receive(waiting)
        #expect(queue.receive(update) == .replacedPending)
        #expect(queue.current == visible)
        #expect(queue.pending == [update])
    }

    // MARK: - AppToastQueue: capacity / overflow

    @Test func queueHoldsAtMostTwoNotices() {
        #expect(AppToastQueue.capacity == 2)
        var queue = AppToastQueue()
        for i in 0..<10 {
            _ = queue.receive(AppToastItem(message: "msg-\(i)", style: .info))
        }
        // The visible pill keeps its slot (it is already being read); the single
        // waiting slot holds the newest notice of equal severity.
        #expect(queue.current?.message == "msg-0")
        #expect(queue.pending.map(\.message) == ["msg-9"])
    }

    @Test func queueOverflowEvictsLessSevereWaitingNotice() {
        var queue = AppToastQueue()
        let visible = AppToastItem(message: "visible", style: .info)
        let routine = AppToastItem(message: "已複製", style: .success)
        let failure = AppToastItem(message: "儲存失敗", style: .error)
        _ = queue.receive(visible)
        _ = queue.receive(routine)
        #expect(queue.receive(failure) == .queued(evicted: routine))
        #expect(queue.pending == [failure])
    }

    @Test func queueOverflowDropsLessSevereNewcomer() {
        var queue = AppToastQueue()
        let visible = AppToastItem(message: "visible", style: .info)
        let failure = AppToastItem(message: "儲存失敗", style: .error)
        let routine = AppToastItem(message: "已複製", style: .success)
        _ = queue.receive(visible)
        _ = queue.receive(failure)
        #expect(queue.receive(routine) == .dropped)
        #expect(queue.current == visible)
        #expect(queue.pending == [failure])
    }

    // MARK: - AppToastQueue: retire / handoff

    @Test func queueRetireWithoutWaitingNoticeNeedsNoHandoff() {
        var queue = AppToastQueue()
        _ = queue.receive(AppToastItem(message: "only", style: .success))
        #expect(queue.retireCurrent() == false)
        #expect(queue.current == nil)
        #expect(!queue.isHandingOff)
    }

    @Test func queueRetireOnEmptyIsNoOp() {
        var queue = AppToastQueue()
        #expect(queue.retireCurrent() == false)
        #expect(queue.current == nil)
    }

    @Test func queueRetireWithWaitingNoticeHandsOffInsteadOfSwappingInPlace() {
        var queue = AppToastQueue()
        let first = AppToastItem(message: "first", style: .info)
        let second = AppToastItem(message: "second", style: .info)
        _ = queue.receive(first)
        _ = queue.receive(second)

        #expect(queue.retireCurrent() == true)
        // The outgoing pill leaves first; the next one is not on screen yet.
        #expect(queue.current == nil)
        #expect(queue.isHandingOff)
        #expect(queue.pending == [second])

        #expect(queue.completeHandoff() == second)
        #expect(queue.current == second)
        #expect(queue.pending.isEmpty)
        #expect(!queue.isHandingOff)
    }

    @Test func queueNewNoticeDuringHandoffWaitsItsTurn() {
        var queue = AppToastQueue()
        let first = AppToastItem(message: "first", style: .info)
        let second = AppToastItem(message: "second", style: .info)
        let third = AppToastItem(message: "third", style: .info)
        _ = queue.receive(first)
        _ = queue.receive(second)
        _ = queue.retireCurrent()

        // Mid-handoff nothing is visible, but `third` must not jump the queue.
        #expect(queue.receive(third) == .queued(evicted: nil))
        #expect(queue.current == nil)
        #expect(queue.pending == [second, third])

        #expect(queue.completeHandoff() == second)
        #expect(queue.pending == [third])
    }

    @Test func queueRetiredEventReappearingDuringHandoffQueuesAsNewOccurrence() {
        var queue = AppToastQueue()
        let first = AppToastItem(message: "first", style: .info)
        let second = AppToastItem(message: "second", style: .info)
        _ = queue.receive(first)
        _ = queue.receive(second)
        _ = queue.retireCurrent()

        let firstAgain = AppToastItem(message: "first", style: .info)
        #expect(queue.receive(firstAgain) == .queued(evicted: nil))
        #expect(queue.pending == [second, firstAgain])
    }

    @Test func queueCompleteHandoffWithoutHandoffIsNoOp() {
        var queue = AppToastQueue()
        let item = AppToastItem(message: "visible", style: .info)
        _ = queue.receive(item)
        #expect(queue.completeHandoff() == nil)
        #expect(queue.current == item)
    }

    // MARK: - Coordinator: present / replace / queue

    @Test func coordinatorStartsEmpty() {
        let coordinator = AppToastCoordinator()
        #expect(coordinator.current == nil)
        #expect(coordinator.pending.isEmpty)
    }

    @Test func showPresentsItem() {
        let coordinator = AppToastCoordinator()
        let item = AppToastItem(message: "hello", style: .info)
        coordinator.show(item)
        #expect(coordinator.current == item)
    }

    @Test func convenienceHelpersSetStyle() {
        // Fresh coordinator per style: different events would queue, not replace.
        let success = AppToastCoordinator()
        success.success("done")
        #expect(success.current?.style == .success)
        #expect(success.current?.message == "done")

        let info = AppToastCoordinator()
        info.info("fyi")
        #expect(info.current?.style == .info)

        let warning = AppToastCoordinator()
        warning.warning("careful")
        #expect(warning.current?.style == .warning)

        let error = AppToastCoordinator()
        error.error("oops")
        #expect(error.current?.style == .error)
        #expect(error.current?.message == "oops")
    }

    @Test func convenienceHelpersForwardExplicitEventKey() {
        let coordinator = AppToastCoordinator()
        coordinator.success("已匯入 1 本", key: "bookshelf.import")
        coordinator.success("已匯入 2 本", key: "bookshelf.import")
        #expect(coordinator.current?.message == "已匯入 2 本")
        #expect(coordinator.pending.isEmpty)
    }

    @Test func coordinatorDifferentEventWaitsForCurrent() {
        let coordinator = AppToastCoordinator()
        coordinator.info("first")
        coordinator.warning("second")
        #expect(coordinator.current?.message == "first")
        #expect(coordinator.pending.map(\.message) == ["second"])
    }

    @Test func coordinatorRepeatedEventIsCollapsed() {
        let coordinator = AppToastCoordinator()
        for _ in 0..<10 {
            coordinator.success("已複製")
        }
        #expect(coordinator.current?.message == "已複製")
        #expect(coordinator.pending.isEmpty)
    }

    // MARK: - Coordinator: dismiss / handoff

    @Test func dismissClearsCurrent() {
        let coordinator = AppToastCoordinator()
        coordinator.success("done")
        #expect(coordinator.current != nil)
        coordinator.dismiss()
        #expect(coordinator.current == nil)
    }

    @Test func dismissOnEmptyIsNoOp() {
        let coordinator = AppToastCoordinator()
        coordinator.dismiss()
        #expect(coordinator.current == nil)
    }

    @Test func dismissHandsOffToWaitingNoticeAfterExitGap() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.info("first")
        coordinator.info("second")
        coordinator.dismiss()

        // Exit animation window: nothing on screen, next notice still waiting.
        #expect(coordinator.current == nil)
        #expect(coordinator.pending.map(\.message) == ["second"])

        clock.advance(by: AppToastCoordinator.handoffDelay)
        #expect(coordinator.current?.message == "second")
        #expect(coordinator.pending.isEmpty)
    }

    @Test func waitingNoticeDoesNotEnterBeforeExitGapElapses() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.info("first")
        coordinator.info("second")
        coordinator.dismiss()
        clock.advance(by: AppToastCoordinator.handoffDelay - .milliseconds(1))
        #expect(coordinator.current == nil)
        #expect(coordinator.pending.map(\.message) == ["second"])
    }

    // MARK: - Coordinator: auto-dismiss timing (fake time)

    @Test func toastPersistsUntilJustBeforeDeadline() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.success("done") // 2.5s
        clock.advance(by: .milliseconds(2_499))
        #expect(coordinator.current?.message == "done")
    }

    @Test func toastAutoDismissesAtDeadline() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.success("done") // 2.5s
        clock.advance(by: .milliseconds(2_500))
        #expect(coordinator.current == nil)
        #expect(clock.scheduledCount == 0)
    }

    @Test func autoDismissUsesTheItemStyleDuration() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.error("failed") // 4.0s
        clock.advance(by: .milliseconds(3_999))
        #expect(coordinator.current?.message == "failed")
        clock.advance(by: .milliseconds(1))
        #expect(coordinator.current == nil)
    }

    @Test func sameEventResetsAutoDismissTimer() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.success("saved") // deadline t=2.5s
        let firstID = coordinator.current?.id
        clock.advance(by: .seconds(2))
        // Same event again before the first deadline: replace in place and
        // restart the timer instead of queueing a duplicate.
        coordinator.success("saved") // deadline t=4.5s
        #expect(coordinator.pending.isEmpty)
        #expect(coordinator.current?.id != firstID)
        #expect(clock.scheduledCount == 1)
        // Past the original deadline (t=2.8s) — the refreshed occurrence must survive.
        clock.advance(by: .milliseconds(800))
        #expect(coordinator.current?.message == "saved")
        // Its own deadline still dismisses it.
        clock.advance(by: .milliseconds(1_700))
        #expect(coordinator.current == nil)
    }

    @Test func queuedNoticeIsShownAfterCurrentExpires() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.success("first") // 2.5s, then handoff gap
        coordinator.success("second")
        clock.advance(by: .milliseconds(2_500))
        #expect(coordinator.current == nil)
        #expect(coordinator.pending.map(\.message) == ["second"])
        clock.advance(by: AppToastCoordinator.handoffDelay)
        #expect(coordinator.current?.message == "second")
        #expect(coordinator.pending.isEmpty)
    }

    @Test func manualDismissCancelsPendingAutoDismiss() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.success("done") // deadline t=2.5s
        coordinator.dismiss()
        #expect(coordinator.current == nil)
        #expect(clock.scheduledCount == 0)
        // A fresh toast must not be cleared at the cancelled timer's deadline.
        coordinator.error("kept") // deadline t=4.0s
        clock.advance(by: .milliseconds(2_500))
        #expect(coordinator.current?.message == "kept")
        clock.advance(by: .milliseconds(1_500))
        #expect(coordinator.current == nil)
    }

    // MARK: - Coordinator: tap-to-expand (#2862)

    @Test func expandedToastGetsAtLeastEightSecondsBeforeDismiss() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.info("long message") // 2.5s normally
        clock.advance(by: .seconds(1))
        coordinator.toggleExpanded()
        #expect(coordinator.isExpanded)
        // Deadline is now t=1s + 8s = t=9s.
        clock.advance(by: .milliseconds(7_999))
        #expect(coordinator.current?.message == "long message")
        clock.advance(by: .milliseconds(1))
        #expect(coordinator.current == nil)
    }

    @Test func expandedWarningKeepsEightSecondFloor() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.warning("warn") // 4.0s, expanded floor 8s
        coordinator.toggleExpanded()
        clock.advance(by: .milliseconds(7_999))
        #expect(coordinator.current != nil)
        clock.advance(by: .milliseconds(1))
        #expect(coordinator.current == nil)
    }

    @Test func collapseRestoresNormalDurationFromCollapseTime() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.info("msg") // 2.5s
        coordinator.toggleExpanded() // t=0, deadline 8s
        clock.advance(by: .seconds(1))
        coordinator.toggleExpanded() // t=1s, collapsed: deadline t=3.5s
        #expect(!coordinator.isExpanded)
        clock.advance(by: .milliseconds(2_499))
        #expect(coordinator.current?.message == "msg")
        clock.advance(by: .milliseconds(1))
        #expect(coordinator.current == nil)
    }

    @Test func toggleWithoutVisibleToastIsNoOp() {
        let coordinator = AppToastCoordinator(scheduler: ManualToastScheduler())
        coordinator.toggleExpanded()
        #expect(!coordinator.isExpanded)
        coordinator.info("next")
        #expect(!coordinator.isExpanded)
    }

    @Test func retireResetsExpansion() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.info("first")
        coordinator.toggleExpanded()
        coordinator.dismiss()
        #expect(!coordinator.isExpanded)
        coordinator.info("second")
        #expect(!coordinator.isExpanded)
        clock.advance(by: .milliseconds(2_500))
        #expect(coordinator.current == nil)
    }

    @Test func sameEventReplacementPreservesExpansionWithFreshFloor() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.info("saved", key: "k")
        coordinator.toggleExpanded() // t=0, deadline 8s
        clock.advance(by: .seconds(2))
        coordinator.info("saved updated", key: "k") // t=2s, deadline t=10s
        #expect(coordinator.isExpanded)
        #expect(coordinator.current?.message == "saved updated")
        clock.advance(by: .milliseconds(7_999))
        #expect(coordinator.current != nil)
        clock.advance(by: .milliseconds(1))
        #expect(coordinator.current == nil)
    }

    @Test func queuedNoticeWaitsBehindExpandedToastWithoutStarving() {
        let clock = ManualToastScheduler()
        let coordinator = AppToastCoordinator(scheduler: clock)
        coordinator.info("first")
        coordinator.info("second")
        coordinator.toggleExpanded()
        clock.advance(by: .milliseconds(7_999))
        #expect(coordinator.current?.message == "first")
        #expect(coordinator.pending.map(\.message) == ["second"])
        clock.advance(by: .milliseconds(1))
        #expect(coordinator.current == nil)
        clock.advance(by: AppToastCoordinator.handoffDelay)
        #expect(coordinator.current?.message == "second")
        #expect(!coordinator.isExpanded)
    }

    // MARK: - Production scheduler contract
    //
    // The fake-time tests above assume `AppToastTaskScheduler` runs an action
    // after its delay and never runs a cancelled one. These tests pin that
    // contract against real time by awaiting the action itself, with no sleep
    // in the test.

    @Test(.timeLimit(.minutes(1)))
    func taskSchedulerRunsActionAfterDelay() async {
        let scheduler = AppToastTaskScheduler()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = scheduler.schedule(after: .milliseconds(1)) {
                continuation.resume()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func taskSchedulerNeverRunsCancelledAction() async {
        let scheduler = AppToastTaskScheduler()
        let fired = FiredActions()
        let cancelled = scheduler.schedule(after: .milliseconds(1)) {
            fired.names.append("cancelled")
        }
        cancelled.cancel()
        // The cancelled action is due first; once the later action has run,
        // an uncancelled one would already have fired too.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = scheduler.schedule(after: .milliseconds(20)) {
                fired.names.append("later")
                continuation.resume()
            }
        }
        #expect(fired.names == ["later"])
    }
}

/// Fake time for `AppToastCoordinator`. `advance(by:)` runs every scheduled,
/// uncancelled action whose deadline falls inside the advanced window, in
/// deadline order, synchronously on the main actor.
@MainActor
private final class ManualToastScheduler: AppToastScheduler {
    private struct Entry {
        let id: Int
        let deadline: Duration
        let action: @MainActor () -> Void
    }

    private var now: Duration = .zero
    private var nextID = 0
    private var entries: [Entry] = []

    /// Actions scheduled and neither run nor cancelled yet.
    var scheduledCount: Int { entries.count }

    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> AppToastScheduledAction {
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, deadline: now + delay, action: action))
        return AppToastScheduledAction { [weak self] in
            self?.entries.removeAll { $0.id == id }
        }
    }

    func advance(by delta: Duration) {
        let target = now + delta
        while let index = nextDueIndex(notAfter: target) {
            let entry = entries.remove(at: index)
            now = entry.deadline
            entry.action()
        }
        now = target
    }

    private func nextDueIndex(notAfter target: Duration) -> Int? {
        entries.indices
            .filter { entries[$0].deadline <= target }
            .min { (entries[$0].deadline, entries[$0].id) < (entries[$1].deadline, entries[$1].id) }
    }
}

/// Records which scheduled actions ran, in order.
@MainActor
private final class FiredActions {
    var names: [String] = []
}
