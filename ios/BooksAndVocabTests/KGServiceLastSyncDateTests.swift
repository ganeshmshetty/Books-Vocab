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

    /// Every cleaner in this file gets temp derived roots: the default `.production` purge would
    /// otherwise delete the real podcast-downloads, podcast-covers and NotebookCovers trees (#3228).
    private struct DerivedFixture {
        let base: URL
        let roots: LocalDataCleanerService.DerivedLocalStateRoots
        let sentinel: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let covers = base.appendingPathComponent("NotebookCovers", isDirectory: true)
            let podcastCovers = base.appendingPathComponent("podcast-covers", isDirectory: true)
            let downloads = base.appendingPathComponent("podcast-downloads", isDirectory: true)
            let series = downloads.appendingPathComponent("series-1", isDirectory: true)
            for dir in [covers, podcastCovers, series] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let sentinel = series.appendingPathComponent("e.mp3")
            FileManager.default.createFile(atPath: sentinel.path, contents: Data([1, 2, 3]))
            self.base = base
            self.sentinel = sentinel
            self.roots = LocalDataCleanerService.DerivedLocalStateRoots(
                notebookCovers: covers,
                podcastCovers: podcastCovers,
                podcastDownloads: downloads
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: base)
        }
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
        let fixture = try DerivedFixture()
        defer { fixture.remove() }

        await LocalDataCleanerService(derivedRoots: fixture.roots).clearLocalData(
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
        let fixture = try DerivedFixture()
        defer { fixture.remove() }

        await LocalDataCleanerService(derivedRoots: fixture.roots).clearLocalData(
            container: try makeEmptyContainer(), reason: "account_switch", deletedAccountID: nil
        )
        // The observer hops to the main actor; let it run.
        for _ in 0..<50 where service.lastSyncDate != nil { try await Task.sleep(for: .milliseconds(20)) }

        #expect(service.lastSyncDate == nil)
    }

    // MARK: - Failed wipe is reported and retried (#2717)

    private struct WipeFailure: Error {}

    /// Throws on the first call, succeeds afterwards: a transient store failure.
    private final class FlakyWipe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []
        func run(_ container: ModelContainer, _ reason: String) async throws {
            let shouldFail: Bool = lock.withLock {
                calls.append(reason)
                return calls.count == 1
            }
            if shouldFail { throw WipeFailure() }
        }
    }

    @Test func failedWipeKeepsCursorsReportsFailureAndRetriesBeforeNextSync() async throws {
        let suite = "kg.test.failedWipe"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set("cursor-A", forKey: KGService.SyncKeys.incrementalBoundary)
        defaults.set("events-A", forKey: KGService.SyncKeys.reviewEventPullBoundary)
        let flaky = FlakyWipe()
        let fixture = try DerivedFixture()
        defer { fixture.remove() }
        let cleaner = LocalDataCleanerService(wipeRows: flaky.run, defaults: defaults, derivedRoots: fixture.roots)
        let container = try makeEmptyContainer()

        let ok = await cleaner.clearLocalDataReportingFailure(
            container: container,
            reason: "user_logout",
            owner: "user-a",
            deletedAccountID: nil
        )

        #expect(ok == false, "failure must be reported to the caller")
        #expect(defaults.string(forKey: KGService.SyncKeys.incrementalBoundary) == "cursor-A", "cursors survive a failed wipe")
        #expect(defaults.string(forKey: KGService.SyncKeys.reviewEventPullBoundary) == "events-A")
        #expect(LocalDataCleanerService.persistedPendingWipeOwner(defaults: defaults) == "user-a")

        let refused = await cleaner.retryPendingLocalWipe(container: container, signedInUserId: "user-b")

        #expect(refused == false, "another account signed in: the leftover rows may hold its unsynced data")
        #expect(flaky.calls.count == 1, "no row wipe under another account")
        #expect(LocalDataCleanerService.persistedPendingWipeOwner(defaults: defaults) == "user-a", "marker keeps its owner")
        #expect(defaults.string(forKey: KGService.SyncKeys.incrementalBoundary) == "cursor-A", "cursors survive a refused retry")

        let finished = await cleaner.retryPendingLocalWipe(container: container, signedInUserId: nil)

        #expect(finished == true)
        #expect(flaky.calls.count == 2, "retry must re-run the row wipe")
        #expect(LocalDataCleanerService.persistedPendingWipeOwner(defaults: defaults) == nil)
        #expect(defaults.object(forKey: KGService.SyncKeys.incrementalBoundary) == nil, "retry success clears cursors")
        #expect(defaults.object(forKey: KGService.SyncKeys.reviewEventPullBoundary) == nil)

        let again = await cleaner.retryPendingLocalWipe(container: container, signedInUserId: nil)
        #expect(again == true)
        #expect(flaky.calls.count == 2, "no marker, no retry")
    }

    /// A failed row wipe still purges derived files, and only under the injected roots: the sentinel
    /// sits in the temp podcast-downloads tree, so its removal proves the purge used the fixture and
    /// never the production Documents tree (#3228).
    @Test func failedWipePurgesInjectedDerivedRootsOnly() async throws {
        let suite = "kg.test.failedWipe.derived"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let fixture = try DerivedFixture()
        defer { fixture.remove() }
        #expect(FileManager.default.fileExists(atPath: fixture.sentinel.path))
        let cleaner = LocalDataCleanerService(
            wipeRows: FlakyWipe().run,
            defaults: defaults,
            derivedRoots: fixture.roots
        )

        let ok = await cleaner.clearLocalDataReportingFailure(
            container: try makeEmptyContainer(),
            reason: "user_logout",
            owner: "user-a",
            deletedAccountID: nil
        )

        #expect(ok == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.sentinel.path), "derived purge must run on a failed wipe")
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
