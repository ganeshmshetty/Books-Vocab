//
//  HealthSnapshotTests.swift
//  Books & Vocab Tests
//
//  鎖 health 探活映射：KGHealthResponse.snapshot 只更新連線狀態 + 卡數，
//  絕不涉及時間欄位。這是「健康檢查不得覆寫 lastSyncDate（最後同步時間）」
//  這條 bug 修復的純 seam —— healthCheck 透過 snapshot 套用狀態，
//  故 snapshot 不含時間 ⇒ healthCheck 不可能再倒退同步時間。
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

private func makeHealth(
    status: String = "ok",
    cards: Int = 0,
    lastModified: String? = nil
) -> KGHealthResponse {
    KGHealthResponse(
        status: status,
        cards: cards,
        links: 0,
        pendingCandidates: 0,
        lastModified: lastModified
    )
}

struct HealthSnapshotTests {

    @Test func snapshotMapsConnectedAndCards() {
        let snap = makeHealth(status: "ok", cards: 636).snapshot
        #expect(snap.isConnected == true)
        #expect(snap.serverCardCount == 636)
    }

    @Test func snapshotNotConnectedWhenStatusNotOk() {
        #expect(makeHealth(status: "degraded").snapshot.isConnected == false)
    }

    /// 核心回歸：即使後端回了 lastModified（8 小時前），snapshot 也只承載
    /// 連線 + 卡數兩個值，沒有任何時間欄位可寫進 lastSyncDate。
    @Test func snapshotIgnoresLastModifiedEntirely() {
        let stale = "2026-06-06T05:00:00Z"
        let a = makeHealth(status: "ok", cards: 636, lastModified: stale).snapshot
        let b = makeHealth(status: "ok", cards: 636, lastModified: nil).snapshot
        // 有無 lastModified 對映射結果完全無差別
        #expect(a == b)
    }
}

// MARK: - #2714 healthCheck must not log out while the keychain token is still loading

/// 只會回報「keychain 讀取待定」的 session store，並記錄所有會寫入／清除 keychain 的呼叫。
private final class RecordingSessionStore: AuthSessionStoring {
    private(set) var clearCount = 0
    private(set) var persistedTokens: [String?] = []

    func loadSession() -> PersistedAuthSession {
        PersistedAuthSession(
            userId: "u-1",
            displayName: nil,
            userEmail: nil,
            avatarURL: nil,
            token: nil,
            keychainReadFailed: true
        )
    }
    func persistProfile(userId: String?, displayName: String?, userEmail: String?, avatarURL: URL?) {}
    func persistToken(_ token: String?) { persistedTokens.append(token) }
    func clearSession() { clearCount += 1 }
}

private final class NoopLocalDataCleaner: LocalDataClearing {
    func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {}
}

private final class NoopAuthVerifier: AuthVerifying {
    func verify(provider: String, token: String, email: String?) async throws -> AuthVerificationResult {
        throw CancellationError()
    }
}

@MainActor
private final class RecordingInvalidator: SessionInvalidating {
    private(set) var logoutReasons: [String] = []
    func logout(modelContainer: ModelContainer?, reason: String) { logoutReasons.append(reason) }
    func waitForPendingLocalDataCleanup() async {}
}

private final class UnreachableTransport: KGHTTPTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
struct HealthCheckPendingTokenTests {
    /// applyPersistedSession 先設 isLoggedIn=true、keychain token 稍後才到；
    /// 這個空窗內的探活不可被當成 401 而登出使用者，也不可清掉 session store／keychain token。
    /// 使用真實 AuthManager（而非 stub）：登出路徑最終會走到 `sessionStore.clearSession()`，
    /// 因此以 store 的呼叫紀錄作為「未清除」的可觀測證據。
    @Test func healthCheckWithPendingTokenDoesNotLogOut() async {
        let store = RecordingSessionStore()
        let auth = AuthManager(
            verifier: NoopAuthVerifier(),
            localDataCleaner: NoopLocalDataCleaner(),
            sessionStore: store,
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
        let service = KGService(
            authSession: auth,
            sessionInvalidator: auth,
            transport: UnreachableTransport(),
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
        await service.healthCheck()
        #expect(auth.isLoggedIn == true, "pending keychain read must keep the session logged in")
        #expect(auth.keychainReadPending == true, "the session must still be in the pending state")
        #expect(store.clearCount == 0, "session store must not be cleared during the pending window")
        #expect(store.persistedTokens.isEmpty, "keychain-backed token must not be written or cleared")
        #expect(service.isConnected == false)
    }
}

// MARK: - #2719 a cancelled probe is not a connectivity verdict

private final class CancellingTransport: KGHTTPTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.cancelled)
    }
}

@MainActor
private final class ReadyTokenAuthSession: AuthSessionProviding {
    let isLoggedIn = true
    let token: String? = "header.eyJleHAiOjQxMzg2Njg0MDB9.signature"
}

@MainActor
struct HealthCheckCancellationTests {
    /// 任務被取消（換頁／timer 重啟）時 healthCheck 不可把已連線狀態翻成離線。
    @Test func cancelledHealthCheckKeepsIsConnected() async {
        let service = KGService(
            authSession: ReadyTokenAuthSession(),
            sessionInvalidator: RecordingInvalidator(),
            transport: CancellingTransport(),
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
        service.isConnected = true
        await service.healthCheck()
        #expect(service.isConnected == true)
    }
}
