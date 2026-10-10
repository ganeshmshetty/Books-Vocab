import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
struct AuthProviderFailureTests {
    private final class NoopVerifier: AuthVerifying {
        func verify(provider: String, token: String, email: String?) async throws -> AuthVerificationResult {
            throw CancellationError()
        }
    }

    private final class EmptySessionStore: AuthSessionStoring {
        func loadSession() -> PersistedAuthSession {
            PersistedAuthSession(
                userId: nil,
                displayName: nil,
                userEmail: nil,
                avatarURL: nil,
                token: nil,
                keychainReadFailed: false
            )
        }

        func persistProfile(userId: String?, displayName: String?, userEmail: String?, avatarURL: URL?) {}
        func persistToken(_ token: String?) {}
        func clearSession() {}
    }

    private final class NoopCleaner: LocalDataClearing {
        func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {}
    }

    @Test func providerFailureIsSurfacedForLoginSheet() {
        let manager = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: NoopCleaner(),
            sessionStore: EmptySessionStore(),
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )

        manager.recordProviderAuthenticationFailure()

        #expect(manager.authError == L10n.string("登入暫時失敗"))
    }
}
