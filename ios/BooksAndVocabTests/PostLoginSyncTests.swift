import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// 釘住登入後同步的帳號邊界語意（#3807）。
///
/// 前一帳號的同步輪仍持有 sync lane 時，登入後的同步必須排隊等待，不得回 `.didNotRun`
/// 把新帳號的第一輪丟掉。cleanup gate 只在 lane 被 claim 後才會被觸及，因此
/// `waitForPendingLocalDataCleanup` 的紀錄可直接證明「一輪真的開始了」，不依賴網路狀態。
@Suite(.serialized)
@MainActor
struct PostLoginSyncTests {

    private final class RecordingInvalidator: SessionInvalidating {
        private(set) var events: [String] = []
        func logout(modelContainer: ModelContainer?, reason: String) {}
        func waitForPendingLocalDataCleanup() async {
            events.append("wait_for_cleanup")
        }
    }

    private final class NilTokenSession: AuthSessionProviding {
        var isLoggedIn: Bool { true }
        var token: String? { nil }
    }

    @MainActor
    private static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            PodcastSeries.self, PodcastEpisode.self,
            configurations: config
        )
    }

    @Test func postLoginSyncQueuesBehindPreviousAccountRound() async {
        let previousAccountRound = KGService()
        #expect(previousAccountRound.claimBackgroundSync())
        defer { previousAccountRound.releaseBackgroundSync() }

        let invalidator = RecordingInvalidator()
        let postLogin = KGService(authSession: NilTokenSession(), sessionInvalidator: invalidator)
        let container = Self.makeContainer()

        let waiter = Task {
            await PostLoginSync.run(on: postLogin, container: container, progress: nil)
        }
        // 讓 waiter 進入 lane 的輪詢迴圈，再釋放前一帳號的 claim。
        try? await Task.sleep(nanoseconds: 100_000_000)
        previousAccountRound.releaseBackgroundSync()

        _ = await waiter.value
        #expect(invalidator.events == ["wait_for_cleanup"],
                "登入後同步必須等前一輪釋放 lane 後實際開跑，實際事件：\(invalidator.events)")
    }

    @Test func postLoginSyncCancelledWhileWaitingStartsNoRound() async {
        let previousAccountRound = KGService()
        #expect(previousAccountRound.claimBackgroundSync())
        defer { previousAccountRound.releaseBackgroundSync() }

        let invalidator = RecordingInvalidator()
        let postLogin = KGService(authSession: NilTokenSession(), sessionInvalidator: invalidator)
        let container = Self.makeContainer()

        let waiter = Task {
            await PostLoginSync.run(on: postLogin, container: container, progress: nil)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()

        let outcome = await waiter.value
        #expect(outcome == .didNotRun)
        #expect(invalidator.events.isEmpty, "取消的等待者不得開始任何一輪同步")
        // 取消後 lane 仍屬於前一帳號；等待者不得偷 claim。
        #expect(!postLogin.claimBackgroundSync())
        previousAccountRound.releaseBackgroundSync()
        #expect(postLogin.claimBackgroundSync(), "取消後 lane 必須能被後續 trigger 正常取得")
        postLogin.releaseBackgroundSync()
    }
}
