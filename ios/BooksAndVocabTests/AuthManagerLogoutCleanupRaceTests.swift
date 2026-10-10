import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Pins the logout-cleanup ↔ re-login race contract（2026-06-09 000287 事故根因）。
///
/// `logout()` 把 `clearLocalData`（清 SwiftData + sync boundary）排進 fire-and-forget
/// Task；使用者在 cleanup 完成前快速重登時，post-login sync 會搶用**尚未被清的**
/// sync boundary（incremental sync 跳過後端全部卡 → 本地空庫但自認最新），且
/// cleanup resume 後會把新 session 剛拉回的資料再清一遍。
///
/// 契約：`waitForPendingLocalDataCleanup()` 必須懸掛到 logout 排程的 cleanup
/// 完成為止 —— post-login sync（BooksAndVocabApp onChange(isLoggedIn)）以它為
/// 前置 gate，保證 full sync 讀到的是已清空的 boundary。連續多次 logout 時
/// cleanup 必須 chain（後一次等前一次收尾），否則兩個 cleanup 並行互踩，
/// gate 只追最新 handle 會漏等仍 in-flight 的前一次。
@MainActor
struct AuthManagerLogoutCleanupRaceTests {

    /// 每次 clearLocalData 進場領一個遞增 run 編號並懸掛在自己的閘門上，直到
    /// 測試顯式 release(run) —— 模擬慢速 cleanup 與快速重登的競態窗口，並支援
    /// 多次 cleanup 的順序斷言。事件順序記錄在 MainActor 上供確定性斷言。
    private final class GatedCleaner: LocalDataClearing, @unchecked Sendable {
        @MainActor private(set) var events: [String] = []
        @MainActor private var nextRun = 0
        @MainActor private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
        @MainActor private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
        @MainActor private var startedRuns: Set<Int> = []
        @MainActor private var finishedRuns: Set<Int> = []

        func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {
            let run: Int = await MainActor.run {
                nextRun += 1
                let run = nextRun
                // 結構性 overlap 偵測：進場時存在已 started 未 finished 的前序 run
                // = 兩個 cleanup 並行（chain 失效）。無 false positive（正確實作
                // 的 happens-before 鏈保證絕不入列）；發生 overlap 即必記錄，但
                // unchained 錯誤實作在極端調度下可能恰好不重疊（review 67c1e824
                // nit 的紅燈強化，覆蓋 false-positive 方向）。
                if startedRuns.contains(where: { !finishedRuns.contains($0) }) {
                    events.append("overlap")
                }
                events.append("cleanup_\(run)_started")
                startedRuns.insert(run)
                startWaiters.removeValue(forKey: run)?.resume()
                return run
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task { @MainActor in
                    gates[run] = continuation
                }
            }
            await MainActor.run {
                finishedRuns.insert(run)
                events.append("cleanup_\(run)_finished")
            }
        }

        @MainActor
        func record(_ event: String) {
            events.append(event)
        }

        @MainActor
        func waitUntilStarted(_ run: Int) async {
            if startedRuns.contains(run) { return }
            await withCheckedContinuation { startWaiters[run] = $0 }
        }

        @MainActor
        func release(_ run: Int) async {
            // gates[run] 由 clearLocalData 內的 Task hop 設置；輪詢到位後放行。
            while gates[run] == nil { await Task.yield() }
            events.append("cleanup_\(run)_released")
            gates.removeValue(forKey: run)?.resume()
        }
    }

    private final class FixedSessionStore: AuthSessionStoring {
        let session: PersistedAuthSession
        init(userId: String?) {
            self.session = PersistedAuthSession(
                userId: userId,
                displayName: nil,
                userEmail: nil,
                avatarURL: nil,
                token: userId == nil ? nil : "tok.\(userId!)",
                keychainReadFailed: false
            )
        }
        func loadSession() -> PersistedAuthSession { session }
        func persistProfile(userId: String?, displayName: String?, userEmail: String?, avatarURL: URL?) {}
        func persistToken(_ token: String?) {}
        func clearSession() {}
    }

    private final class NoopVerifier: AuthVerifying {
        func verify(provider: String, token: String, email: String?) async throws -> AuthVerificationResult {
            throw CancellationError()
        }
    }

    @MainActor
    private static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(for: Notebook.self, configurations: config)
    }

    private func makeManager(priorUserId: String?, cleaner: any LocalDataClearing) -> AuthManager {
        let manager = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: cleaner,
            sessionStore: FixedSessionStore(userId: priorUserId),
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
        manager.modelContainer = Self.makeContainer()
        return manager
    }

    /// 核心契約：cleanup 未完成前 wait 必懸掛；事件序必為
    /// started → released → finished → wait_finished（錯誤實作會讓
    /// wait_finished 搶在 released 之前 —— 確定性紅燈，無 timing flake）。
    @Test func waitSuspendsUntilLogoutCleanupFinishes() async {
        let cleaner = GatedCleaner()
        let manager = makeManager(priorUserId: "user-a", cleaner: cleaner)

        manager.logout(reason: "race_test")
        await cleaner.waitUntilStarted(1)

        // 模擬競態窗口中的快速重登 + post-login gate。
        manager.login(userId: "user-a", token: "fresh-token")
        let waiter = Task { @MainActor in
            await manager.waitForPendingLocalDataCleanup()
            cleaner.record("wait_finished")
        }

        await cleaner.release(1)
        await waiter.value

        #expect(cleaner.events == [
            "cleanup_1_started",
            "cleanup_1_released",
            "cleanup_1_finished",
            "wait_finished"
        ], "wait 必須排在 cleanup 完成之後，實際順序：\(cleaner.events)")
    }

    /// 無 pending cleanup（從未登出）時，gate 立即返回 —— 正常冷啟登入不被拖慢。
    @Test func waitReturnsImmediatelyWhenNoCleanupPending() async {
        let cleaner = GatedCleaner()
        let manager = makeManager(priorUserId: nil, cleaner: cleaner)

        await manager.waitForPendingLocalDataCleanup()

        #expect(cleaner.events.isEmpty)
    }

    /// 連續兩次 logout（logout₁ → 重登 → logout₂ → 重登）：cleanup 必須 chain ——
    /// cleanup₂ 不得在 cleanup₁ 完成前動工（兩個並行 cleanup 各持獨立
    /// BackgroundSyncActor，互踩會重演 000287：後完成的把新 session 拉回的
    /// 資料再清一遍）；且 gate 雖只追最新 handle，chain 保證等到 handle₂
    /// 即隱含 cleanup₁ 也已收尾。
    @Test func secondLogoutCleanupWaitsForFirstToFinish() async {
        let cleaner = GatedCleaner()
        let manager = makeManager(priorUserId: "user-a", cleaner: cleaner)

        manager.logout(reason: "first")
        await cleaner.waitUntilStarted(1)

        // cleanup₁ 仍懸掛中：快速重登 → 再登出 → 再重登。
        manager.login(userId: "user-a", token: "t1")
        manager.logout(reason: "second")
        manager.login(userId: "user-a", token: "t2")

        let waiter = Task { @MainActor in
            await manager.waitForPendingLocalDataCleanup()
            cleaner.record("wait_finished")
        }

        await cleaner.release(1)
        // chain 契約：cleanup₂ 要等 cleanup₁ 完成才 started。
        await cleaner.waitUntilStarted(2)
        await cleaner.release(2)
        await waiter.value

        #expect(cleaner.events == [
            "cleanup_1_started",
            "cleanup_1_released",
            "cleanup_1_finished",
            "cleanup_2_started",
            "cleanup_2_released",
            "cleanup_2_finished",
            "wait_finished"
        ], "cleanup 必須 chain、wait 必須殿後，實際順序：\(cleaner.events)")
    }

    /// gate 懸掛期間又發生 logout（chain 出 cleanup₂）：wait 不得在 cleanup₁
    /// 完成時就放行（單次快照 TOCTOU —— sync 會與 cleanup₂ 並行，重演 000287
    /// 形態），必須 re-check 並繼續等到鏈上最後一個 cleanup 收尾。
    @Test func waitFollowsCleanupChainedWhileSuspended() async {
        let cleaner = GatedCleaner()
        let manager = makeManager(priorUserId: "user-a", cleaner: cleaner)

        manager.logout(reason: "first")
        await cleaner.waitUntilStarted(1)
        manager.login(userId: "user-a", token: "t1")

        let waiter = Task { @MainActor in
            await manager.waitForPendingLocalDataCleanup()
            cleaner.record("wait_finished")
        }
        // 讓 waiter 先懸掛到 cleanup₁ 上，再於懸掛期間二次 logout。
        await Task.yield()

        manager.logout(reason: "second")
        manager.login(userId: "user-a", token: "t2")

        await cleaner.release(1)
        await cleaner.waitUntilStarted(2)
        await cleaner.release(2)
        await waiter.value

        #expect(cleaner.events.last == "wait_finished",
                "wait 必須等完 chain 上最後一個 cleanup，實際順序：\(cleaner.events)")
        #expect(!cleaner.events.contains("overlap"),
                "cleanup 不得並行，實際順序：\(cleaner.events)")
    }
}
