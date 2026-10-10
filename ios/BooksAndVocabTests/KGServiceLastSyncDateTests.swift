import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Pins the persistence of "when did this device last sync".
///
/// `lastSyncDate` used to live only in memory, so Settings showed no sync time
/// at all after every cold start — the field was there, the row just had
/// nothing to render until that session's first sync happened to finish.
@MainActor
struct KGServiceLastSyncDateTests {

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "kg.test.lastSyncDate.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test func absentKeyReadsAsNeverSynced() {
        let defaults = makeDefaults()

        #expect(KGService.loadPersistedLastSyncDate(defaults: defaults) == nil)
    }

    /// `UserDefaults.double(forKey:)` answers 0 for a missing key, which would
    /// render as "last synced in 1970" — an unknown time must stay unknown.
    @Test func missingKeyIsNotReadAsEpoch() {
        let defaults = makeDefaults()
        defaults.set(0.0, forKey: KGService.SyncKeys.lastSyncDate)

        #expect(KGService.loadPersistedLastSyncDate(defaults: defaults) == nil)
    }

    @Test func persistedDateSurvivesAReload() {
        let defaults = makeDefaults()
        let synced = Date(timeIntervalSince1970: 1_800_000_000)

        KGService.persistLastSyncDate(synced, defaults: defaults)

        let reloaded = try? #require(KGService.loadPersistedLastSyncDate(defaults: defaults))
        #expect(reloaded?.timeIntervalSince1970 == synced.timeIntervalSince1970)
    }

    /// Logout / account switch clears it, so the next account never inherits
    /// the previous account's sync time.
    @Test func clearingRemovesThePersistedValue() {
        let defaults = makeDefaults()
        KGService.persistLastSyncDate(Date(timeIntervalSince1970: 1_800_000_000), defaults: defaults)

        KGService.persistLastSyncDate(nil, defaults: defaults)

        #expect(KGService.loadPersistedLastSyncDate(defaults: defaults) == nil)
    }

    // MARK: - Logout / account-switch cleanup (#2424)

    private func makeEmptyContainer() throws -> ModelContainer {
        try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    /// `clearLocalData` is the single logout / account-switch cleanup path; it
    /// must drop the persisted sync time so a cold start never shows account A's
    /// "synced ..." under account B.
    @Test func localDataCleanupRemovesPersistedLastSyncDate() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: KGService.SyncKeys.lastSyncDate)
        defer {
            if let prior { defaults.set(prior, forKey: KGService.SyncKeys.lastSyncDate) }
            else { defaults.removeObject(forKey: KGService.SyncKeys.lastSyncDate) }
        }
        KGService.persistLastSyncDate(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(KGService.loadPersistedLastSyncDate() != nil)

        await LocalDataCleanerService().clearLocalData(
            container: try makeEmptyContainer(), reason: "user_logout", deletedAccountID: nil
        )

        #expect(KGService.loadPersistedLastSyncDate() == nil)
    }

    /// The in-memory value also resets, without a relaunch: a live `KGService`
    /// observes `.localUserDataDidClear`.
    @Test func liveServiceLastSyncDateResetsOnLocalDataClear() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: KGService.SyncKeys.lastSyncDate)
        defer {
            if let prior { defaults.set(prior, forKey: KGService.SyncKeys.lastSyncDate) }
            else { defaults.removeObject(forKey: KGService.SyncKeys.lastSyncDate) }
        }
        let service = KGService()
        service.lastSyncDate = Date(timeIntervalSince1970: 1_800_000_000)

        await LocalDataCleanerService().clearLocalData(
            container: try makeEmptyContainer(), reason: "account_switch", deletedAccountID: nil
        )
        // The observer hops to the main actor; let it run.
        for _ in 0..<50 where service.lastSyncDate != nil { try await Task.sleep(for: .milliseconds(20)) }

        #expect(service.lastSyncDate == nil)
    }
}

/// Pins the pipeline-pending retry schedule.
///
/// It was a flat 10s × 3. The server's AI pipeline usually finishes within a
/// couple of seconds, so a fixed 10s meant the card sat in "Pending" for a full
/// 10s *after* it was ready — most of the wait was the client not looking, not
/// the server still working.
struct SyncPipelineBackoffTests {

    @Test func backoffStartsWithinOneSecond() {
        #expect(syncPipelinePendingBackoffSeconds.first == 1)
    }

    @Test func backoffIsMonotonicallyIncreasing() {
        let schedule = syncPipelinePendingBackoffSeconds
        #expect(zip(schedule, schedule.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// More attempts than before, in half the total wall clock.
    @Test func backoffRetriesMoreOftenWithinASmallerBudget() {
        let schedule = syncPipelinePendingBackoffSeconds
        #expect(schedule.count > 3)
        #expect(schedule.reduce(0, +) < 30)
    }
}
