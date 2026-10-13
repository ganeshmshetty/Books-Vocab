//
//  BooksAndVocabTests.swift
//  Books & Vocab Tests
//
//  Created by 陳亮宇 on 2026/2/24.
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

struct BooksAndVocabTests {
    @Test func appObservationStoreCapsPreviewToMostRecentEntries() async throws {
        let store = AppObservationStore.shared
        store.clear()
        defer { store.clear() }

        for index in 0..<12 {
            store.record(level: .info, category: "test", message: "event=\(index)")
        }

        let preview = store.preview(limit: 5)

        #expect(preview.totalCount == 12)
        #expect(preview.entries.count == 5)
        #expect(preview.entries.first?.message == "event=7")
        #expect(preview.entries.last?.message == "event=11")
    }

    @Test func analyticsObservationPreviewRedactsSensitiveWordContent() async throws {
        let store = AppObservationStore.shared
        store.clear()
        defer { store.clear() }

        AppAnalytics.track(.translationRequested(word: "secret", type: .quick))

        let preview = store.preview(limit: 1)
        let message = try #require(preview.entries.first?.message)

        #expect(message.contains("event=translation_requested"))
        #expect(message.contains("chars=6"))
        #expect(message.contains("secret") == false)
    }

    @Test func sessionMetricsResetClearsAggregatesBetweenSnapshots() async throws {
        let metrics = SessionMetrics.shared
        metrics.reset()

        metrics.record(.syncCompleted(durationMs: 320, outcome: .success))
        metrics.record(.reviewCardSubmitted(feedback: "remembered", cardIndex: 0, totalCards: 1))
        let first = metrics.snapshot()

        #expect(first.syncCount == 1)
        #expect(first.reviewCardsTotal == 1)

        metrics.reset()
        let second = metrics.snapshot()

        #expect(second.syncCount == 0)
        #expect(second.reviewCardsTotal == 0)
    }

    @Test func reviewSettingsStoreDefaultsAutoplaySoundOn() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-settings-autoplay-sound-default"))
        defaults.removePersistentDomain(forName: "review-settings-autoplay-sound-default")
        defer { defaults.removePersistentDomain(forName: "review-settings-autoplay-sound-default") }

        let store = ReviewSettingsStore(defaults: defaults)

        #expect(store.settings.autoplaySoundEnabled)
    }

    @Test func reviewSettingsStorePersistsAutoplaySoundPreference() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-settings-autoplay-sound-persist"))
        defaults.removePersistentDomain(forName: "review-settings-autoplay-sound-persist")
        defer { defaults.removePersistentDomain(forName: "review-settings-autoplay-sound-persist") }

        let store = ReviewSettingsStore(defaults: defaults)
        var settings = store.settings
        settings.autoplaySoundEnabled = false
        store.update(settings)

        let restored = ReviewSettingsStore(defaults: defaults)

        #expect(restored.settings.autoplaySoundEnabled == false)
    }

    @Test func reviewSessionStoreRestoresKgBackedOrderAcrossLocalUUIDChanges() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-session-order-kg"))
        defaults.removePersistentDomain(forName: "review-session-order-kg")
        defer { defaults.removePersistentDomain(forName: "review-session-order-kg") }

        let first = Self.makeReviewEntry("alpha", kgCardId: "card-alpha")
        let second = Self.makeReviewEntry("beta", kgCardId: "card-beta")
        ReviewSessionStore.saveOrder([second, first], userID: "user-1", defaults: defaults)

        let replacementFirst = Self.makeReviewEntry("alpha", kgCardId: "card-alpha")
        let replacementSecond = Self.makeReviewEntry("beta", kgCardId: "card-beta")
        let restored = ReviewSessionStore.loadOrder(
            availableEntries: [replacementFirst, replacementSecond],
            userID: "user-1",
            defaults: defaults
        )

        #expect(restored?.map(\.kgCardId) == ["card-beta", "card-alpha"])
    }

    @Test func reviewSessionStoreRestoresLocalOrderForUnsyncedCards() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-session-order-local"))
        defaults.removePersistentDomain(forName: "review-session-order-local")
        defer { defaults.removePersistentDomain(forName: "review-session-order-local") }

        let first = Self.makeReviewEntry("alpha")
        let second = Self.makeReviewEntry("beta")
        ReviewSessionStore.saveOrder([second, first], userID: nil, defaults: defaults)

        let restored = ReviewSessionStore.loadOrder(
            availableEntries: [first, second],
            userID: nil,
            defaults: defaults
        )

        #expect(restored?.map(\.id) == [second.id, first.id])
    }

    @Test func reviewSessionStoreIsolatesOrderByUser() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-session-order-user"))
        defaults.removePersistentDomain(forName: "review-session-order-user")
        defer { defaults.removePersistentDomain(forName: "review-session-order-user") }

        let first = Self.makeReviewEntry("alpha", kgCardId: "card-alpha")
        let second = Self.makeReviewEntry("beta", kgCardId: "card-beta")
        ReviewSessionStore.saveOrder([second, first], userID: "user-A", defaults: defaults)

        let restored = ReviewSessionStore.loadOrder(
            availableEntries: [first, second],
            userID: "user-B",
            defaults: defaults
        )

        #expect(restored == nil)
    }

    @Test func reviewSessionStoreDoesNotApplyLegacyOrderForLoggedInUser() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-session-order-legacy-user"))
        defaults.removePersistentDomain(forName: "review-session-order-legacy-user")
        defer { defaults.removePersistentDomain(forName: "review-session-order-legacy-user") }

        let first = Self.makeReviewEntry("alpha")
        let second = Self.makeReviewEntry("beta")
        defaults.set([second.id.uuidString, first.id.uuidString], forKey: "kg.review.shuffledOrder")

        let restored = ReviewSessionStore.loadOrder(
            availableEntries: [first, second],
            userID: "user-1",
            defaults: defaults
        )

        #expect(restored == nil)
    }

    @Test func reviewSessionStoreClearsLegacyOrderForGuest() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-session-order-clear-legacy"))
        defaults.removePersistentDomain(forName: "review-session-order-clear-legacy")
        defer { defaults.removePersistentDomain(forName: "review-session-order-clear-legacy") }

        let first = Self.makeReviewEntry("alpha")
        let second = Self.makeReviewEntry("beta")
        defaults.set([second.id.uuidString, first.id.uuidString], forKey: "kg.review.shuffledOrder")

        ReviewSessionStore.clear(userID: nil, defaults: defaults)

        let restored = ReviewSessionStore.loadOrder(
            availableEntries: [first, second],
            userID: nil,
            defaults: defaults
        )

        #expect(restored == nil)
    }

    @Test func reviewSessionStoreRejectsDifferentQueueFingerprint() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-session-order-fingerprint"))
        defaults.removePersistentDomain(forName: "review-session-order-fingerprint")
        defer { defaults.removePersistentDomain(forName: "review-session-order-fingerprint") }

        let first = Self.makeReviewEntry("alpha", kgCardId: "card-alpha")
        let second = Self.makeReviewEntry("beta", kgCardId: "card-beta")
        let third = Self.makeReviewEntry("gamma", kgCardId: "card-gamma")
        ReviewSessionStore.saveOrder([second, first], userID: "user-1", defaults: defaults)

        let restored = ReviewSessionStore.loadOrder(
            availableEntries: [first, third],
            userID: "user-1",
            defaults: defaults
        )

        #expect(restored == nil)
    }

    @Test func reviewSessionStoreFiltersMissingCardsAndAppendsNewCards() async throws {
        let defaults = try #require(UserDefaults(suiteName: "review-session-order-append"))
        defaults.removePersistentDomain(forName: "review-session-order-append")
        defer { defaults.removePersistentDomain(forName: "review-session-order-append") }

        let first = Self.makeReviewEntry("alpha", kgCardId: "card-alpha")
        let second = Self.makeReviewEntry("beta", kgCardId: "card-beta")
        ReviewSessionStore.saveOrder([second, first], userID: "user-1", defaults: defaults)

        let replacementFirst = Self.makeReviewEntry("alpha", kgCardId: "card-alpha")
        let newThird = Self.makeReviewEntry("gamma", kgCardId: "card-gamma")
        let restored = ReviewSessionStore.loadOrder(
            availableEntries: [replacementFirst, newThird],
            userID: "user-1",
            allowPartialQueue: true,
            defaults: defaults
        )

        #expect(restored?.map(\.kgCardId) == ["card-alpha", "card-gamma"])
    }

    @Test @MainActor func todayReviewStateRestoresProgressAcrossSessionReload() async throws {
        TodayReviewSessionSnapshotStore.clear(for: nil)
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)

        let first = VocabularyEntry(word: "lucid", translation: "清晰", context: "A lucid answer.", bookTitle: "Sample")
        first.kgCardId = "card-lucid"
        first.markSynced()
        let second = VocabularyEntry(word: "evoke", translation: "喚起", context: "Evoke memory.", bookTitle: "Sample")
        second.kgCardId = "card-evoke"
        second.markSynced()
        context.insert(first)
        context.insert(second)
        #expect(context.safeSave())

        let state = TodayReviewState(
            entries: [first, second],
            allEntries: [first, second],
            currentUserID: "user-1"
        )
        state.submit(.remembered, container: container, reviewSettings: .default)
        try await Task.sleep(for: .milliseconds(100))

        let replacementFirst = VocabularyEntry(word: "lucid", translation: "清晰", context: "A lucid answer.", bookTitle: "Sample")
        replacementFirst.kgCardId = "card-lucid"
        replacementFirst.markSynced()
        let replacementSecond = VocabularyEntry(word: "evoke", translation: "喚起", context: "Evoke memory.", bookTitle: "Sample")
        replacementSecond.kgCardId = "card-evoke"
        replacementSecond.markSynced()
        let restored = TodayReviewState(
            entries: [replacementFirst, replacementSecond],
            allEntries: [replacementFirst, replacementSecond],
            currentUserID: "user-1"
        )

        #expect(restored.currentIndex == 1)
        #expect(restored.rememberedCount == 1)
        #expect(restored.forgotCount == 0)
        #expect(restored.progressText == "1 / 2")
        TodayReviewSessionSnapshotStore.clear(for: nil)
    }

    @Test @MainActor func todayReviewStateFlushesAnswerOncePerCard() async throws {
        TodayReviewSessionSnapshotStore.clear(for: nil)
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)

        let first = VocabularyEntry(word: "lucid", translation: "清晰", context: "A lucid answer.", bookTitle: "Sample")
        first.kgCardId = "card-lucid"
        first.markSynced()
        let second = VocabularyEntry(word: "evoke", translation: "喚起", context: "Evoke memory.", bookTitle: "Sample")
        second.kgCardId = "card-evoke"
        second.markSynced()
        context.insert(first)
        context.insert(second)
        #expect(context.safeSave())

        let state = TodayReviewState(
            entries: [first, second],
            allEntries: [first, second],
            currentUserID: "user-1"
        )
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.goPrevious()
        state.submit(.forgot, container: container, reviewSettings: .default)
        // Persistence is deferred off the per-flip hot path: the per-card submit no
        // longer writes SwiftData (a per-flip store merge froze the next-card render).
        // The batched flush (driven by the view's onDisappear in production) is what
        // reaches the store — and it must stay idempotent: exactly one record per card.
        state.flushPendingAnswers(container: container, reviewSettings: .default)
        // The flush body runs on `Task.detached(priority: .utility)` (see
        // ReviewSessionPersistence.flushPendingAnswers), so a fixed `sleep(100ms)`
        // asserts "this machine was fast enough", not "the write landed". Three
        // unrelated branches were blocked by that race in one day, and the failure
        // reads as data loss (all three assertions come back empty) rather than as a
        // timing problem, which is why it kept getting attributed to the branch.
        //
        // Wait for the store to actually hold the record instead, with a ceiling: a
        // flush that never lands still fails, in bounded time, so this hides no real
        // regression — it only stops the test from asserting on the scheduler.
        var records: [ReviewRecord] = []
        for _ in 0..<400 {                                  // ceiling: 400 * 25ms = 10s
            records = try context.fetch(FetchDescriptor<ReviewRecord>())
            if !records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        let entry = try context.fetch(FetchDescriptor<VocabularyEntry>()).first { $0.kgCardId == "card-lucid" }

        // Remember → back → Forget: the new answer REPLACES the old one (issue #2025);
        // still exactly one review / one record for the card.
        #expect(entry?.reviewCount == 1)
        #expect(entry?.lastReviewFeedbackRaw == ReviewFeedback.forgot.rawValue)
        #expect(records.count == 1)
        #expect(records.first?.feedback == ReviewFeedback.forgot.rawValue)
        #expect(state.currentIndex == 1)
        TodayReviewSessionSnapshotStore.clear(for: nil)
    }

    @Test @MainActor func mixedNotebookFlushResolvesPolicyPerEntry() async throws {
        TodayReviewSessionSnapshotStore.clear(for: nil)
        defer { TodayReviewSessionSnapshotStore.clear(for: nil) }

        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)

        let custom = VocabularyEntry(
            word: "custom", translation: "自訂", context: "A custom policy.", bookTitle: "Sample"
        )
        custom.kgCardId = "card-custom"
        custom.notebookId = "notebook-custom"
        custom.markSynced()

        let global = VocabularyEntry(
            word: "global", translation: "全域", context: "The global policy.", bookTitle: "Sample"
        )
        global.kgCardId = "card-global"
        global.notebookId = "notebook-global"
        global.markSynced()

        context.insert(custom)
        context.insert(global)
        #expect(context.safeSave())

        let state = TodayReviewState(
            entries: [custom, global],
            allEntries: [custom, global],
            currentUserID: "mixed-policy-user"
        )
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.submit(.remembered, container: container, reviewSettings: .default)

        let customPolicy = ReviewPolicy(
            mode: .custom,
            customInitialIntervalHours: 3,
            customRememberedMultiplier: 1.7,
            customForgotMultiplier: 0.4,
            customMinimumIntervalHours: 2,
            customMaximumIntervalHours: 900
        )
        let snapshot = NotebookSettingsResolver(
            globalReviewSettings: .default,
            globalCardLayout: .default,
            overrides: [
                "notebook-custom": NotebookSettingsOverride(reviewPolicy: customPolicy, cardLayout: nil)
            ]
        ).snapshot(for: ["notebook-custom", "notebook-global"])
        state.flushPendingAnswers(container: container, notebookSettingsSnapshot: snapshot)

        var records: [ReviewRecord] = []
        for _ in 0..<400 {
            records = try context.fetch(FetchDescriptor<ReviewRecord>())
            if records.count == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        let savedEntries = try context.fetch(FetchDescriptor<VocabularyEntry>())
        let savedCustom = savedEntries.first { $0.kgCardId == "card-custom" }
        let savedGlobal = savedEntries.first { $0.kgCardId == "card-global" }

        #expect(abs((savedCustom?.reviewIntervalHours ?? 0) - 5.1) < 0.001)
        #expect(savedGlobal?.reviewIntervalHours == 60)
        #expect(records.count == 2)
    }

    @Test func todayReviewSnapshotIsolatesPerUserOnSave() async throws {
        TodayReviewSessionSnapshotStore.clear(for: nil)
        defer { TodayReviewSessionSnapshotStore.clear(for: nil) }

        func makeSnapshot(userId: String, currentIndex: Int) -> TodayReviewSessionSnapshotStore.Snapshot {
            let baseline = TodayReviewSessionSnapshotStore.ReviewBaseline(
                reviewIntervalHours: 24,
                nextReviewAt: Date(),
                lastReviewedAt: nil,
                reviewCount: 0,
                lapseCount: 0,
                reviewStreak: 0,
                lastReviewFeedbackRaw: 0
            )
            return TodayReviewSessionSnapshotStore.Snapshot(
                userId: userId,
                sessionStartTime: Date(),
                currentIndex: currentIndex,
                queue: [
                    .init(persistenceID: "card-\(userId)", baseline: baseline)
                ],
                submissions: [:],
                updatedAt: Date()
            )
        }

        // user A has in-progress review at index 3
        TodayReviewSessionSnapshotStore.save(makeSnapshot(userId: "user-A", currentIndex: 3))
        // user B logs in and starts their own review (index 0)
        TodayReviewSessionSnapshotStore.save(makeSnapshot(userId: "user-B", currentIndex: 0))

        // user A switches back: their snapshot must NOT have been overwritten
        let restoredA = TodayReviewSessionSnapshotStore.load(for: "user-A")
        #expect(restoredA != nil)
        #expect(restoredA?.userId == "user-A")
        #expect(restoredA?.currentIndex == 3)

        // user B still intact too
        let restoredB = TodayReviewSessionSnapshotStore.load(for: "user-B")
        #expect(restoredB?.currentIndex == 0)

        // clearing user B leaves user A untouched
        TodayReviewSessionSnapshotStore.clear(for: "user-B")
        #expect(TodayReviewSessionSnapshotStore.load(for: "user-B") == nil)
        #expect(TodayReviewSessionSnapshotStore.load(for: "user-A")?.currentIndex == 3)
    }

    @Test @MainActor func clearLocalDataPurgesTodayReviewSnapshotStore() async throws {
        TodayReviewSessionSnapshotStore.clear(for: nil)
        defer { TodayReviewSessionSnapshotStore.clear(for: nil) }

        func makeSnapshot(userId: String) -> TodayReviewSessionSnapshotStore.Snapshot {
            let baseline = TodayReviewSessionSnapshotStore.ReviewBaseline(
                reviewIntervalHours: 24,
                nextReviewAt: Date(),
                lastReviewedAt: nil,
                reviewCount: 0,
                lapseCount: 0,
                reviewStreak: 0,
                lastReviewFeedbackRaw: 0
            )
            return TodayReviewSessionSnapshotStore.Snapshot(
                userId: userId,
                sessionStartTime: Date(),
                currentIndex: 2,
                queue: [.init(persistenceID: "card-\(userId)", baseline: baseline)],
                submissions: [:],
                updatedAt: Date()
            )
        }

        // Two users have in-progress review snapshots persisted on this device.
        TodayReviewSessionSnapshotStore.save(makeSnapshot(userId: "user-A"))
        TodayReviewSessionSnapshotStore.save(makeSnapshot(userId: "user-B"))
        #expect(TodayReviewSessionSnapshotStore.load(for: "user-A") != nil)
        #expect(TodayReviewSessionSnapshotStore.load(for: "user-B") != nil)

        // Logout / account-switch both route through LocalDataCleanerService.clearLocalData.
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        await LocalDataCleanerService().clearLocalData(container: container, reason: "user_logout", deletedAccountID: nil)

        // No stale today-review session may survive logout.
        #expect(TodayReviewSessionSnapshotStore.load(for: "user-A") == nil)
        #expect(TodayReviewSessionSnapshotStore.load(for: "user-B") == nil)
    }

    // MARK: - Review flush consistency (Track 24)

    /// A persisted answer carries its DB-flush state. New answers default to
    /// unflushed; the snapshot round-trip preserves the flag.
    @Test func submittedAnswerFlushFlagRoundTripsThroughSnapshot() async throws {
        TodayReviewSessionSnapshotStore.clear(for: nil)
        defer { TodayReviewSessionSnapshotStore.clear(for: nil) }

        let baseline = TodayReviewSessionSnapshotStore.ReviewBaseline(
            reviewIntervalHours: 24, nextReviewAt: Date(), lastReviewedAt: nil,
            reviewCount: 0, lapseCount: 0, reviewStreak: 0, lastReviewFeedbackRaw: 0
        )
        let snapshot = TodayReviewSessionSnapshotStore.Snapshot(
            userId: "user-flush",
            sessionStartTime: Date(),
            currentIndex: 2,
            queue: [.init(persistenceID: "card-x", baseline: baseline)],
            submissions: [
                0: .init(feedbackRaw: 0, answeredAt: Date(), reviewRecordID: UUID(), flushed: true),
                1: .init(feedbackRaw: 1, answeredAt: Date(), reviewRecordID: UUID(), flushed: false)
            ],
            updatedAt: Date()
        )
        TodayReviewSessionSnapshotStore.save(snapshot)

        let restored = try #require(TodayReviewSessionSnapshotStore.load(for: "user-flush"))
        #expect(restored.submissions[0]?.flushed == true)
        #expect(restored.submissions[1]?.flushed == false)
    }

    /// Backward compat: a legacy snapshot blob written before the `flushed`
    /// field existed must decode with `flushed == true` (those answers were
    /// already flushed; never re-flush historical data).
    @Test func legacySnapshotWithoutFlushFieldDecodesAsFlushed() async throws {
        // Hand-built JSON mirroring the pre-flushed-field encoding: a
        // SubmittedAnswer with no `flushed` key.
        let json = """
        {
          "feedbackRaw": 0,
          "answeredAt": 0,
          "reviewRecordID": "\(UUID().uuidString)"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(
            TodayReviewSessionSnapshotStore.Snapshot.SubmittedAnswer.self,
            from: data
        )
        #expect(decoded.flushed == true)
    }

    /// Store-layer legacy migration: a bare `Snapshot` blob (pre per-user
    /// keying) seeded directly into the defaults key must load per-user and be
    /// re-persisted as the dictionary shape. Seeds UserDefaults underneath the
    /// store, so the warm in-memory cache must be invalidated first — without
    /// that, the cache silently masks the seeded blob and the decode/migration
    /// path never runs.
    @Test func legacyBareSnapshotBlobMigratesToPerUserStore() async throws {
        TodayReviewSessionSnapshotStore.clear(for: nil)
        defer { TodayReviewSessionSnapshotStore.clear(for: nil) }

        let baseline = TodayReviewSessionSnapshotStore.ReviewBaseline(
            reviewIntervalHours: 24, nextReviewAt: Date(), lastReviewedAt: nil,
            reviewCount: 0, lapseCount: 0, reviewStreak: 0, lastReviewFeedbackRaw: 0
        )
        let legacy = TodayReviewSessionSnapshotStore.Snapshot(
            userId: "user-legacy",
            sessionStartTime: Date(),
            currentIndex: 1,
            queue: [.init(persistenceID: "card-legacy", baseline: baseline)],
            submissions: [:],
            updatedAt: Date()
        )
        let blob = try JSONEncoder().encode(legacy)
        // Drain the async clear() above BEFORE seeding underneath the store —
        // otherwise the queued clear can run after the direct set and delete
        // the seeded blob. queue.sync doubles as the drain barrier.
        TodayReviewSessionSnapshotStore._invalidateCacheForTesting()
        UserDefaults.standard.set(blob, forKey: "kg.review.activeSession.v1")
        TodayReviewSessionSnapshotStore._invalidateCacheForTesting()

        let restored = try #require(TodayReviewSessionSnapshotStore.load(for: "user-legacy"))
        #expect(restored.userId == "user-legacy")
        #expect(restored.queue.first?.persistenceID == "card-legacy")

        // Migration must have re-persisted the dictionary shape: a cold
        // re-decode (cache dropped again) still finds the per-user entry.
        TodayReviewSessionSnapshotStore._invalidateCacheForTesting()
        #expect(TodayReviewSessionSnapshotStore.load(for: "user-legacy") != nil)
    }

    /// New answers persisted by submit() start unflushed; once the DB flush
    /// succeeds the snapshot is rewritten with flushed=true so restore won't
    /// re-flush. Verified at the scoring layer (markFlushed).
    @Test @MainActor func scoringMarkFlushedFlipsAnswerFlag() async throws {
        let scoring = ReviewScoringState()
        let sent = scoring.record(.remembered, at: 0)
        #expect(scoring.submittedAnswers[0]?.flushed == false)

        scoring.markFlushed(at: 0, confirming: sent)
        #expect(scoring.submittedAnswers[0]?.flushed == true)

        // Marking a non-existent index is a no-op (no crash).
        scoring.markFlushed(at: 99, confirming: sent)
    }

    /// #3409 at the scoring layer: a confirmation for a submission that has since been replaced must
    /// not flip the replacement's flag.
    @Test @MainActor func scoringMarkFlushedIgnoresReplacedSubmission() {
        let scoring = ReviewScoringState()
        let sent = scoring.record(.remembered, at: 0)
        scoring.score(.forgot, at: 0)

        scoring.markFlushed(at: 0, confirming: sent)
        #expect(scoring.submittedAnswers[0]?.feedback == .forgot)
        #expect(scoring.submittedAnswers[0]?.flushed == false)
    }

    @Test func readerBridgePlannerEmitsSingleWordHighlightCommand() async throws {
        var planner = BridgePlanner()
        let base = makeSnapshot(lookedUpWords: [])
        _ = planner.makeCommands(from: base)

        let commands = planner.makeCommands(from: makeSnapshot(lookedUpWords: ["resilient"]))

        #expect(commands.contains { command in
            if case .dom(.markNewVocabWord("resilient")) = command { return true }
            return false
        })
    }

    @Test func readerBridgePlannerClearsAndReappliesOnLargeRemoval() async throws {
        var planner = BridgePlanner()
        let originalWords = (0..<12).map { "word\($0)" }
        _ = planner.makeCommands(from: makeSnapshot(lookedUpWords: originalWords))

        let commands = planner.makeCommands(from: makeSnapshot(lookedUpWords: ["word1"]))

        #expect(commands.contains { command in
            if case .dom(.clearAllVocabHighlights) = command { return true }
            return false
        })
        #expect(commands.contains { command in
            if case .dom(.markVocabWords(let words)) = command {
                return words == ["word1"]
            }
            return false
        })
    }

    @Test func readerBridgePlannerOnlyClearsHighlightOncePerTrigger() async throws {
        var planner = BridgePlanner()
        let trigger = UUID()

        let first = planner.makeCommands(from: makeSnapshot(lookedUpWords: [], clearHighlightTrigger: trigger))
        let second = planner.makeCommands(from: makeSnapshot(lookedUpWords: [], clearHighlightTrigger: trigger))

        #expect(first.contains { command in
            if case .dom(.clearActiveHighlight) = command { return true }
            return false
        })
        #expect(second.contains { command in
            if case .dom(.clearActiveHighlight) = command { return true }
            return false
        } == false)
    }

    @Test func vocabularyEntryPendingAddLifecycleIsVisibleInReaderButNotKnowledgeList() async throws {
        let entry = VocabularyEntry(
            word: "evoke",
            translation: "喚起",
            context: "The story can evoke old memories.",
            bookTitle: "Sample"
        )

        entry.restorePendingEntry()

        #expect(entry.isPending)
        #expect(entry.isPendingAdd)
        #expect(entry.shouldUploadOnNextSync)
        #expect(entry.shouldAppearInReader)
        #expect(entry.shouldAppearInKnowledgeList == false)
    }

    @Test func vocabularyEntryPendingDeleteLifecycleHidesFromReaderUntilServerDeleteCompletes() async throws {
        let entry = VocabularyEntry(
            word: "lucid",
            translation: "清晰的",
            context: "Her explanation was lucid.",
            bookTitle: "Sample"
        )

        entry.markSynced()
        entry.queueDelete()

        #expect(entry.isPending)
        #expect(entry.isPendingDelete)
        #expect(entry.shouldUploadOnNextSync)
        #expect(entry.shouldAppearInReader == false)
        #expect(entry.shouldAppearInKnowledgeList == false)
    }

    @Test func vocabularyEntryFailedDeleteRemainsRetryableAndHidden() async throws {
        let entry = VocabularyEntry(
            word: "obsolete",
            translation: "過時",
            context: "That term is obsolete.",
            bookTitle: "Sample"
        )

        entry.markSynced()
        entry.queueDelete()
        entry.markSyncFailed()

        #expect(entry.isFailed)
        #expect(entry.isFailedDelete)
        #expect(entry.shouldUploadOnNextSync)
        #expect(entry.shouldAppearInReader == false)
        #expect(entry.shouldAppearInKnowledgeList == false)
    }

    @Test func vocabularyEntryFailedAddCanReturnToPendingForRetry() async throws {
        let entry = VocabularyEntry(
            word: "evoke",
            translation: "喚起",
            context: "The story can evoke old memories.",
            bookTitle: "Sample"
        )

        entry.restorePendingEntry()
        entry.markSyncFailed()
        entry.prepareForRetryAttempt()

        #expect(entry.isPending)
        #expect(entry.isPendingAdd)
        #expect(entry.shouldUploadOnNextSync)
    }

    @Test func vocabularyEntryPresentationSeparatesPendingQueueFromKnowledgeLibrary() async throws {
        let pendingAdd = VocabularyEntry(
            word: "evoke",
            translation: "喚起",
            context: "The story can evoke old memories.",
            bookTitle: "Sample"
        )
        pendingAdd.restorePendingEntry()

        let synced = VocabularyEntry(
            word: "lucid",
            translation: "清晰的",
            context: "Her explanation was lucid.",
            bookTitle: "Sample"
        )
        synced.markSynced()

        let pendingDelete = VocabularyEntry(
            word: "obsolete",
            translation: "過時",
            context: "That term is obsolete.",
            bookTitle: "Sample"
        )
        pendingDelete.markSynced()
        pendingDelete.queueDelete()

        let failedAdd = VocabularyEntry(
            word: "resilient",
            translation: "有韌性的",
            context: "She stayed resilient.",
            bookTitle: "Sample"
        )
        failedAdd.restorePendingEntry()
        failedAdd.markSyncFailed()

        let entries = [pendingAdd, synced, pendingDelete, failedAdd]

        #expect(VocabularyEntryPresentation.pendingEntries(in: entries).map(\.word).sorted() == ["evoke", "obsolete", "resilient"])
        let classified = VocabularyEntryPresentation.classifyKnowledgeEntries(in: entries, now: Date())
        let allSynced = classified.dueBucket + classified.unlearnedBucket + classified.reviewedBucket
        #expect(allSynced.map(\.word) == ["lucid"])
    }

    // MARK: - mutateLink / insertLink helpers

    @Test func mutateLinkReplacesExistingLink() {
        let entry = VocabularyEntry(word: "test", translation: "測試", context: "ctx", bookTitle: "B")
        let link = KGCardLinkSummary(id: "link-1", cardId: "c1", word: "alpha", kind: "synonym", label: "synonym", confidence: 0.9, reason: "test")
        entry.graphLinksByKind = ["synonym": [link]]

        let result = entry.mutateLink(id: "link-1") { $0.withHidden(true) }

        #expect(result != nil)
        #expect(result?.kind == "synonym")
        #expect(result?.link.isHidden == false)
        #expect(entry.graphLinksByKind["synonym"]?.first?.isHidden == true)
    }

    @Test func mutateLinkRemovesLinkWhenTransformReturnsNil() {
        let entry = VocabularyEntry(word: "test", translation: "測試", context: "ctx", bookTitle: "B")
        let link = KGCardLinkSummary(id: "link-1", cardId: "c1", word: "alpha", kind: "synonym", label: "synonym", confidence: 0.9, reason: "test")
        entry.graphLinksByKind = ["synonym": [link]]

        let result = entry.mutateLink(id: "link-1") { _ in nil }

        #expect(result != nil)
        #expect(result?.link.id == "link-1")
        // group should be cleaned up
        #expect(entry.graphLinksByKind["synonym"] == nil)
    }

    @Test func mutateLinkReturnsNilWhenNotFound() {
        let entry = VocabularyEntry(word: "test", translation: "測試", context: "ctx", bookTitle: "B")
        entry.graphLinksByKind = [:]

        let result = entry.mutateLink(id: "nonexistent") { $0.withHidden(true) }

        #expect(result == nil)
    }

    @Test func insertLinkAddsToCorrectKindGroup() {
        let entry = VocabularyEntry(word: "test", translation: "測試", context: "ctx", bookTitle: "B")
        let existing = KGCardLinkSummary(id: "link-1", cardId: "c1", word: "alpha", kind: "synonym", label: "synonym", confidence: 0.9, reason: "test")
        entry.graphLinksByKind = ["synonym": [existing]]

        let newLink = KGCardLinkSummary(id: "link-2", cardId: "c2", word: "beta", kind: "antonym", label: "antonym", confidence: 0.8, reason: "test")
        entry.insertLink(newLink, kind: "antonym")

        #expect(entry.graphLinksByKind["antonym"]?.count == 1)
        #expect(entry.graphLinksByKind["antonym"]?.first?.id == "link-2")
        #expect(entry.graphLinksByKind["synonym"]?.count == 1)
    }

    // MARK: - Bilateral hide/unhide/delete tests

    private func makeBilateralPair() -> (a: VocabularyEntry, b: VocabularyEntry, linkAtoB: KGCardLinkSummary, linkBtoA: KGCardLinkSummary) {
        let a = VocabularyEntry(word: "lucid", translation: "清晰", context: "ctx", bookTitle: "B")
        a.kgCardId = "card-a"
        let b = VocabularyEntry(word: "vivid", translation: "鮮明", context: "ctx", bookTitle: "B")
        b.kgCardId = "card-b"

        let linkAtoB = KGCardLinkSummary(id: "link-1", cardId: "card-b", word: "vivid", kind: "synonym", label: "同義", confidence: 0.9, reason: "test")
        let linkBtoA = KGCardLinkSummary(id: "link-1", cardId: "card-a", word: "lucid", kind: "synonym", label: "同義", confidence: 0.9, reason: "test")

        a.graphLinksByKind = ["synonym": [linkAtoB]]
        b.graphLinksByKind = ["synonym": [linkBtoA]]

        return (a, b, linkAtoB, linkBtoA)
    }

    @Test func bilateralHideOptimisticUpdateUpdatesBothEntries() {
        let (a, b, _, _) = makeBilateralPair()

        _ = a.mutateLink(id: "link-1") { $0.withHidden(true) }
        _ = b.mutateLink(id: "link-1") { $0.withHidden(true) }

        #expect(a.graphLinksByKind["synonym"]?.first?.isHidden == true)
        #expect(b.graphLinksByKind["synonym"]?.first?.isHidden == true)
    }

    @Test func bilateralHideRollbackRestoresBothEntriesOnAPIFailure() {
        let (a, b, _, _) = makeBilateralPair()

        let resultA = a.mutateLink(id: "link-1") { $0.withHidden(true) }
        let resultB = b.mutateLink(id: "link-1") { $0.withHidden(true) }

        // Simulate API failure → rollback using originals
        if let rA = resultA {
            _ = a.mutateLink(id: "link-1") { _ in rA.link }
        }
        if let rB = resultB {
            _ = b.mutateLink(id: "link-1") { _ in rB.link }
        }

        #expect(a.graphLinksByKind["synonym"]?.first?.isHidden == false)
        #expect(b.graphLinksByKind["synonym"]?.first?.isHidden == false)
    }

    @Test func bilateralUnhideOptimisticUpdateUpdatesBothEntries() {
        let (a, b, _, _) = makeBilateralPair()

        // First hide both
        _ = a.mutateLink(id: "link-1") { $0.withHidden(true) }
        _ = b.mutateLink(id: "link-1") { $0.withHidden(true) }

        // Now unhide both
        _ = a.mutateLink(id: "link-1") { $0.withHidden(false) }
        _ = b.mutateLink(id: "link-1") { $0.withHidden(false) }

        #expect(a.graphLinksByKind["synonym"]?.first?.isHidden == false)
        #expect(b.graphLinksByKind["synonym"]?.first?.isHidden == false)
    }

    @Test func bilateralUnhideRollbackRestoresBothEntriesOnAPIFailure() {
        let (a, b, _, _) = makeBilateralPair()

        // Start hidden
        _ = a.mutateLink(id: "link-1") { $0.withHidden(true) }
        _ = b.mutateLink(id: "link-1") { $0.withHidden(true) }

        // Optimistic unhide
        let resultA = a.mutateLink(id: "link-1") { $0.withHidden(false) }
        let resultB = b.mutateLink(id: "link-1") { $0.withHidden(false) }

        // API failure → rollback to hidden
        if let rA = resultA {
            _ = a.mutateLink(id: "link-1") { _ in rA.link }
        }
        if let rB = resultB {
            _ = b.mutateLink(id: "link-1") { _ in rB.link }
        }

        #expect(a.graphLinksByKind["synonym"]?.first?.isHidden == true)
        #expect(b.graphLinksByKind["synonym"]?.first?.isHidden == true)
    }

    @Test func bilateralDeleteOptimisticUpdateRemovesFromBothEntries() {
        let (a, b, _, _) = makeBilateralPair()

        _ = a.mutateLink(id: "link-1") { _ in nil }
        _ = b.mutateLink(id: "link-1") { _ in nil }

        #expect(a.graphLinksByKind["synonym"] == nil)
        #expect(b.graphLinksByKind["synonym"] == nil)
    }

    @Test func bilateralDeleteRollbackReinsertsIntoBothEntriesOnAPIFailure() {
        let (a, b, _, _) = makeBilateralPair()

        let resultA = a.mutateLink(id: "link-1") { _ in nil }
        let resultB = b.mutateLink(id: "link-1") { _ in nil }

        // Rollback via insertLink
        if let rA = resultA {
            a.insertLink(rA.link, kind: rA.kind)
        }
        if let rB = resultB {
            b.insertLink(rB.link, kind: rB.kind)
        }

        #expect(a.graphLinksByKind["synonym"]?.count == 1)
        #expect(a.graphLinksByKind["synonym"]?.first?.id == "link-1")
        #expect(b.graphLinksByKind["synonym"]?.count == 1)
        #expect(b.graphLinksByKind["synonym"]?.first?.id == "link-1")
    }

    @Test func bilateralCounterpartMissingDoesNotCrashAndStillUpdatesCurrent() {
        let a = VocabularyEntry(word: "lucid", translation: "清晰", context: "ctx", bookTitle: "B")
        a.kgCardId = "card-a"
        let linkAtoB = KGCardLinkSummary(id: "link-1", cardId: "card-b", word: "vivid", kind: "synonym", label: "同義", confidence: 0.9, reason: "test")
        a.graphLinksByKind = ["synonym": [linkAtoB]]

        // b is nil / not found — only mutate a
        _ = a.mutateLink(id: "link-1") { $0.withHidden(true) }
        // No counterpart to mutate — should not crash

        #expect(a.graphLinksByKind["synonym"]?.first?.isHidden == true)
    }

    // MARK: - Notebook orphan sync defense (incident 2026-04-11)

    @MainActor
    private func makeNotebookSandbox() throws -> ModelContext {
        let container = try ModelContainer(
            for: VocabularyEntry.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    /// Helper: insert a sentinel notebook so the table is not empty,
    /// satisfying `resolveNotebookId`'s cold-start guard. Without this,
    /// resolver returns the candidate verbatim and tests asserting the
    /// fallback behavior would silently pass for the wrong reason.
    @MainActor
    private func primeNotebookTable(_ ctx: ModelContext) throws {
        let primer = Notebook(remoteId: "primer-\(UUID().uuidString)", name: "Primer", color: nil)
        ctx.insert(primer)
        try ctx.save()
    }

    @Test @MainActor
    func resolveNotebookId_emptyCandidate_returnsDefault() throws {
        let ctx = try makeNotebookSandbox()
        #expect(VocabularyEntry.resolveNotebookId("", in: ctx) == "default")
    }

    @Test @MainActor
    func resolveNotebookId_defaultCandidate_returnsDefault() throws {
        let ctx = try makeNotebookSandbox()
        #expect(VocabularyEntry.resolveNotebookId("default", in: ctx) == "default")
    }

    @Test @MainActor
    func resolveNotebookId_validNotebook_returnsItself() throws {
        let ctx = try makeNotebookSandbox()
        let nb = Notebook(remoteId: "live-abc", name: "Self", color: nil)
        ctx.insert(nb)
        try ctx.save()
        #expect(VocabularyEntry.resolveNotebookId("live-abc", in: ctx) == "live-abc")
    }

    @Test @MainActor
    func resolveNotebookId_unsavedNotebook_returnsItself() throws {
        // Production race: notebook just created, not yet saved, then
        // sync triggers. Resolver must see in-memory pending insert.
        let ctx = try makeNotebookSandbox()
        let nb = Notebook(remoteId: "fresh", name: "Fresh", color: nil)
        ctx.insert(nb)
        // intentionally NO try ctx.save()
        #expect(VocabularyEntry.resolveNotebookId("fresh", in: ctx) == "fresh")
    }

    @Test @MainActor
    func resolveNotebookId_deletedNotebook_returnsDefault() throws {
        let ctx = try makeNotebookSandbox()
        // Pair a live notebook to confirm the predicate's positive arm works
        // (without this paired assertion, the test would also pass if the
        // table simply contained no `ghost` row at all, hiding a regression
        // where the `!$0.isSoftDeleted` clause is removed).
        let live = Notebook(remoteId: "live", name: "Live", color: nil)
        ctx.insert(live)
        try ctx.save()
        #expect(VocabularyEntry.resolveNotebookId("live", in: ctx) == "live")

        let ghost = Notebook(remoteId: "ghost", name: "Ghost", color: nil)
        ctx.insert(ghost)
        ghost.isSoftDeleted = true   // mutate after insert so it goes through persistent path
        try ctx.save()

        #expect(VocabularyEntry.resolveNotebookId("ghost", in: ctx) == "default")
    }

    @Test @MainActor
    func resolveNotebookId_unknownNotebook_returnsDefault() throws {
        let ctx = try makeNotebookSandbox()
        try primeNotebookTable(ctx)  // satisfy cold-start guard
        #expect(VocabularyEntry.resolveNotebookId("nonexistent", in: ctx) == "default")
    }

    @Test @MainActor
    func resolveNotebookId_emptyNotebookTable_returnsCandidateUnchanged() throws {
        // Cold-start guard: no notebooks fetched yet (first launch / fresh
        // login). Resolver must NOT clobber a legitimately-bound id —
        // returns it verbatim until reconcile populates the table.
        let ctx = try makeNotebookSandbox()
        #expect(VocabularyEntry.resolveNotebookId("possibly-real", in: ctx) == "possibly-real")
    }

    @Test @MainActor
    func sanitizeOutbox_emptyArray_isNoOp() throws {
        let ctx = try makeNotebookSandbox()
        SyncCoordinator.sanitizeOutbox(pendingEntries: [], modelContext: ctx)
        // Reaching here without crash is the assertion.
    }

    @Test @MainActor
    func sanitizeOutbox_orphanAdd_isReassignedToDefault() throws {
        let ctx = try makeNotebookSandbox()
        let ghost = Notebook(remoteId: "ghost", name: "Ghost", color: nil)
        ctx.insert(ghost)
        ghost.isSoftDeleted = true
        try ctx.save()

        let entry = VocabularyEntry(
            word: "orphan",
            translation: "孤兒",
            context: "An orphan card.",
            bookTitle: "Sample"
        )
        entry.notebookId = "ghost"
        entry.restorePendingEntry()  // queue as pending add
        ctx.insert(entry)
        try ctx.save()

        // Arrange-side guard: if `restorePendingEntry()` ever stops setting
        // pending state, the test below would silently green-pass without
        // exercising sanitize. Fail fast on the precondition.
        #expect(entry.shouldUploadOnNextSync)
        #expect(entry.syncAction == .add)

        SyncCoordinator.sanitizeOutbox(pendingEntries: [entry], modelContext: ctx)

        #expect(entry.notebookId == "default")
        #expect(entry.syncAction == .add)  // still queued for upload
    }

    @Test @MainActor
    func sanitizeOutbox_orphanDelete_isHardDeletedLocally() throws {
        // Pending-delete orphan must NOT be rewritten to default — that
        // could trigger a server delete of an unrelated card with the same
        // word in default. Drop locally instead.
        let ctx = try makeNotebookSandbox()
        let ghost = Notebook(remoteId: "ghost", name: "Ghost", color: nil)
        ctx.insert(ghost)
        ghost.isSoftDeleted = true
        try ctx.save()

        let entry = VocabularyEntry(
            word: "doomed",
            translation: "註定",
            context: "Doomed context.",
            bookTitle: "Sample"
        )
        entry.notebookId = "ghost"
        entry.markSynced()
        entry.queueDelete()
        ctx.insert(entry)
        try ctx.save()
        #expect(entry.shouldUploadOnNextSync)

        SyncCoordinator.sanitizeOutbox(pendingEntries: [entry], modelContext: ctx)

        // After sanitize, the entry should be hard-deleted from local store.
        let remaining = (try? ctx.fetch(FetchDescriptor<VocabularyEntry>())) ?? []
        #expect(remaining.contains(where: { $0.word == "doomed" }) == false)
    }

    @Test @MainActor
    func sanitizeOutbox_validPendingEntry_isUnchanged() throws {
        let ctx = try makeNotebookSandbox()
        let valid = Notebook(remoteId: "live-xyz", name: "Live", color: nil)
        ctx.insert(valid)
        try ctx.save()

        let entry = VocabularyEntry(
            word: "good",
            translation: "好",
            context: "Good context.",
            bookTitle: "Sample"
        )
        entry.notebookId = "live-xyz"
        entry.restorePendingEntry()
        ctx.insert(entry)
        try ctx.save()

        SyncCoordinator.sanitizeOutbox(pendingEntries: [entry], modelContext: ctx)

        #expect(entry.notebookId == "live-xyz")
        #expect(entry.syncState == .pending)
        #expect(entry.syncAction == .add)
    }

    @Test @MainActor
    func sanitizeOutbox_syncedOrphan_isNotTouched() throws {
        // Synced entries are out of the outbox — sanitize must skip them
        // even if their notebookId points to a deleted notebook. Mutating
        // a synced entry's notebookId would drift local from server.
        let ctx = try makeNotebookSandbox()
        let ghost = Notebook(remoteId: "ghost", name: "Ghost", color: nil)
        ctx.insert(ghost)
        ghost.isSoftDeleted = true
        try ctx.save()

        let entry = VocabularyEntry(
            word: "settled",
            translation: "已定",
            context: "Settled context.",
            bookTitle: "Sample"
        )
        entry.notebookId = "ghost"
        entry.markSynced()
        ctx.insert(entry)
        try ctx.save()
        #expect(entry.shouldUploadOnNextSync == false)  // arrange guard

        SyncCoordinator.sanitizeOutbox(pendingEntries: [entry], modelContext: ctx)

        #expect(entry.notebookId == "ghost")  // unchanged
    }

    @Test @MainActor
    func sanitizeOutbox_alreadyDefault_isUnchanged() throws {
        let ctx = try makeNotebookSandbox()
        try primeNotebookTable(ctx)

        let entry = VocabularyEntry(
            word: "anchor",
            translation: "錨",
            context: "Anchor context.",
            bookTitle: "Sample"
        )
        // notebookId already "default"
        entry.restorePendingEntry()
        ctx.insert(entry)
        try ctx.save()

        SyncCoordinator.sanitizeOutbox(pendingEntries: [entry], modelContext: ctx)

        #expect(entry.notebookId == "default")
    }

    @Test @MainActor
    func sanitizeOutbox_emptyNotebookId_isReassignedToDefault() throws {
        // Edge case: legacy entries (or post-migration noise) could have
        // notebookId == "". Resolver short-circuits to "default", and
        // sanitize must apply that fix.
        let ctx = try makeNotebookSandbox()
        try primeNotebookTable(ctx)

        let entry = VocabularyEntry(
            word: "blank",
            translation: "空",
            context: "Blank context.",
            bookTitle: "Sample"
        )
        entry.notebookId = ""
        entry.restorePendingEntry()
        ctx.insert(entry)
        try ctx.save()

        SyncCoordinator.sanitizeOutbox(pendingEntries: [entry], modelContext: ctx)

        #expect(entry.notebookId == "default")
    }

    @Test
    func triggerPipelinesIsolated_failingNotebookDoesNotBlockOthers() async {
        // Real regression guard: calls SyncCoordinator's actual static
        // helper that startSync delegates to. If anyone refactors the
        // production loop back to fail-fast, this test will catch it.
        actor MockKG {
            var calls: [String] = []
            var failOn: Set<String> = []
            func setFailing(_ ids: [String]) { failOn = Set(ids) }
            func trigger(_ id: String) async throws {
                calls.append(id)
                if failOn.contains(id) {
                    throw URLError(.userAuthenticationRequired)  // proxy for HTTP 403
                }
            }
        }
        let mock = MockKG()
        await mock.setFailing(["4205d6bed3ed"])

        // Worst-case ordering: failing notebook first.
        let failures = await SyncCoordinator.triggerPipelinesIsolated(
            notebookIds: ["4205d6bed3ed", "default"]
        ) { nbId in
            try await mock.trigger(nbId)
        }

        let calls = await mock.calls
        #expect(calls == ["4205d6bed3ed", "default"])  // BOTH called
        #expect(failures == ["4205d6bed3ed"])
    }

    @Test
    func triggerPipelinesIsolated_allSuccess_returnsEmptyFailures() async {
        actor MockKG {
            var calls: [String] = []
            func trigger(_ id: String) async { calls.append(id) }
        }
        let mock = MockKG()
        let failures = await SyncCoordinator.triggerPipelinesIsolated(
            notebookIds: ["default"]
        ) { nbId in
            await mock.trigger(nbId)
        }
        #expect(failures.isEmpty)
        let calls = await mock.calls
        #expect(calls == ["default"])
    }

    @Test
    func triggerPipelinesIsolated_allFail_returnsAllFailures() async {
        let failures = await SyncCoordinator.triggerPipelinesIsolated(
            notebookIds: ["a", "b", "c"]
        ) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(failures == ["a", "b", "c"])
    }

    @Test @MainActor
    func sanitizeOutbox_tombstonedOrphanDelete_isExcludedFromDownstreamFilters() throws {
        // Regression guard for the tombstone-defense fix in startSync's
        // deletes/adds filters. After sanitize hard-deletes an orphan-delete
        // entry, the caller's [VocabularyEntry] snapshot still references it.
        // Filters that build the upload batches MUST exclude entries returned
        // by sanitize's stable deleted-id set; PersistentModel.isDeleted is not
        // a reliable save-after lifecycle contract.
        let ctx = try makeNotebookSandbox()
        let ghost = Notebook(remoteId: "ghost", name: "Ghost", color: nil)
        ctx.insert(ghost)
        ghost.isSoftDeleted = true
        let live = Notebook(remoteId: "live", name: "Live", color: nil)
        ctx.insert(live)
        try ctx.save()

        // Mix: one orphan delete (will be tombstoned by sanitize), one valid add
        let orphanDelete = VocabularyEntry(
            word: "doomed", translation: "註定", context: "ctx", bookTitle: "B"
        )
        orphanDelete.notebookId = "ghost"
        orphanDelete.markSynced()
        orphanDelete.queueDelete()
        ctx.insert(orphanDelete)

        let validAdd = VocabularyEntry(
            word: "alive", translation: "活著", context: "ctx", bookTitle: "B"
        )
        validAdd.notebookId = "live"
        validAdd.restorePendingEntry()
        ctx.insert(validAdd)
        try ctx.save()

        let snapshot = [orphanDelete, validAdd]
        let sanitizedDeletedIds = SyncCoordinator.sanitizeOutbox(
            pendingEntries: snapshot,
            modelContext: ctx
        )

        // Mirror the production filters from startSync. The orphanDelete is
        // tombstoned and MUST be excluded; validAdd survives.
        let deletes = snapshot.filter {
            !sanitizedDeletedIds.contains($0.id) && $0.syncAction == .delete && $0.shouldUploadOnNextSync
        }
        let adds = snapshot.filter {
            !sanitizedDeletedIds.contains($0.id) && $0.syncAction == .add && $0.shouldUploadOnNextSync
        }

        #expect(deletes.isEmpty)  // tombstone defense
        #expect(adds.count == 1)
        #expect(adds.first?.word == "alive")
    }

    // MARK: - batch-delete not_found convergence (track-7)

    @Test @MainActor
    func locallyResolvableDeletes_unionsDeletedAndNotFound() {
        // not_found = server 上已不存在 = 刪除意圖已達成 = 可本地收斂。
        // 必須與 deleted_words 走同一條本地刪除路徑，否則永久卡死重試。
        let response = KGBatchDeleteResponse(
            deleted: 2,
            deleted_words: ["alpha", "beta"],
            not_found: ["gamma", "delta"]
        )
        let resolvable = SyncCoordinator.locallyResolvableDeletes(from: response)
        #expect(resolvable == ["alpha", "beta", "gamma", "delta"])
    }

    @Test @MainActor
    func locallyResolvableDeletes_overlapIsDeduped() {
        // 防禦：deleted_words 與 not_found 若 server 端意外重疊，Set union 去重。
        let response = KGBatchDeleteResponse(
            deleted: 1,
            deleted_words: ["alpha"],
            not_found: ["alpha"]
        )
        #expect(SyncCoordinator.locallyResolvableDeletes(from: response) == ["alpha"])
    }

    @Test @MainActor
    func locallyResolvableArchives_unionsUpdatedAndNotFound() {
        let response = KGBatchArchiveResponse(
            updated: 2,
            updated_words: ["alpha", "beta"],
            not_found: ["gamma", "delta"]
        )

        let resolvable = KGVocabCoordinator.locallyResolvableArchives(from: response)

        #expect(resolvable == ["alpha", "beta", "gamma", "delta"])
    }

    @Test @MainActor
    func batchArchiveClassification_notFoundConvergesLocally_notCountedFailed() {
        let updatedWord = VocabularyEntry(word: "alpha", translation: "t", context: "ctx", bookTitle: "B")
        let notFoundWord = VocabularyEntry(word: "gamma", translation: "t", context: "ctx", bookTitle: "B")
        let stuckWord = VocabularyEntry(word: "omega", translation: "t", context: "ctx", bookTitle: "B")
        let entries = [updatedWord, notFoundWord, stuckWord]

        let response = KGBatchArchiveResponse(
            updated: 1,
            updated_words: ["alpha"],
            not_found: ["gamma"]
        )

        let resolvableSet = KGVocabCoordinator.locallyResolvableArchives(from: response)
        var failCount = 0
        for entry in entries {
            if resolvableSet.contains(entry.word) {
                entry.isArchived = true
            } else {
                failCount += 1
            }
        }

        #expect(updatedWord.isArchived)
        #expect(notFoundWord.isArchived)
        #expect(!stuckWord.isArchived)
        #expect(failCount == 1)
    }

    @Test @MainActor
    func batchDeleteClassification_notFoundConvergesLocally_notMarkedFailed() throws {
        // Full-fidelity regression guard over real VocabularyEntry + ModelContext:
        // calls the SAME `applyBatchDeleteResponse` static helper that startSync's
        // batch-delete happy path delegates to（曾是手抄 mirror loop——抽共用後
        // 消除 dead-test 風險，比照 triggerPipelinesIsolated）。Asserts a
        // not_found word is LOCALLY DELETED (intent met), a deleted_words word
        // is locally deleted, and a genuinely-unresolved word (in neither list
        // = real server anomaly) is markSyncFailed for retry.
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let ctx = ModelContext(container)

        func makePendingDelete(_ word: String) -> VocabularyEntry {
            let e = VocabularyEntry(word: word, translation: "t", context: "ctx", bookTitle: "B")
            e.markSynced()
            e.queueDelete()
            ctx.insert(e)
            return e
        }
        let deletedWord = makePendingDelete("alpha")    // server deleted this call
        let notFoundWord = makePendingDelete("gamma")   // server: already gone
        let stuckWord = makePendingDelete("omega")      // neither → real anomaly
        try ctx.save()

        let entries = [deletedWord, notFoundWord, stuckWord]
        let response = KGBatchDeleteResponse(
            deleted: 1,
            deleted_words: ["alpha"],
            not_found: ["gamma"]
        )

        let outcome = SyncCoordinator.applyBatchDeleteResponse(
            response: response, entries: entries, modelContext: ctx
        )
        try ctx.save()

        #expect(outcome.deleted == 2)            // alpha + gamma 皆本地收斂
        #expect(outcome.failedWords == ["omega"])

        let remainingWords = try ctx.fetch(FetchDescriptor<VocabularyEntry>()).map(\.word)

        // not_found + deleted_words → locally hard-deleted.
        #expect(!remainingWords.contains(deletedWord.word))
        #expect(!remainingWords.contains(notFoundWord.word))
        #expect(!notFoundWord.isFailed)  // crucial: NOT stuck in failed+delete retry

        // Only the genuinely-unresolved word stays as a retryable failure.
        #expect(remainingWords.contains(stuckWord.word))
        #expect(stuckWord.isFailedDelete)
    }

    @Test func mutateLinkCleansUpEmptyGroup() {
        let entry = VocabularyEntry(word: "test", translation: "測試", context: "ctx", bookTitle: "B")
        let link1 = KGCardLinkSummary(id: "link-1", cardId: "c1", word: "alpha", kind: "synonym", label: "synonym", confidence: 0.9, reason: "test")
        let link2 = KGCardLinkSummary(id: "link-2", cardId: "c2", word: "beta", kind: "synonym", label: "synonym", confidence: 0.8, reason: "test")
        entry.graphLinksByKind = ["synonym": [link1, link2]]

        // Remove first link — group still has one
        _ = entry.mutateLink(id: "link-1") { _ in nil }
        #expect(entry.graphLinksByKind["synonym"]?.count == 1)

        // Remove second link — group should be cleaned up
        _ = entry.mutateLink(id: "link-2") { _ in nil }
        #expect(entry.graphLinksByKind["synonym"] == nil)
    }

    private func makeSnapshot(
        lookedUpWords: [String],
        clearHighlightTrigger: UUID = UUID(),
        underlineOpacity: Double = 0.22,
        showHitTestingDebug: Bool = false
    ) -> ReadiumNavigatorView.BridgeSnapshot {
        // ReaderViewConfiguration is built via ReaderSettings.viewConfiguration(systemColorScheme:);
        // post-refactor `translationPanelMode` was removed from the struct.
        let baseConfig = ReaderSettings.shared.viewConfiguration(systemColorScheme: .light)
        let configuration = ReaderViewConfiguration(
            paperColor: AppColors.paperSepia,
            epubPreferences: baseConfig.epubPreferences,
            underlineOpacity: underlineOpacity,
            showHitTestingDebug: showHitTestingDebug,
            swiftUIColorScheme: .light
        )

        return .init(
            lookedUpWords: lookedUpWords,
            bookUniqueWords: Set(lookedUpWords),
            viewConfiguration: configuration,
            clearHighlightTrigger: clearHighlightTrigger,
            removeWordTrigger: nil,
            navigateToLocator: nil,
            isInteractionBlocked: false
        )
    }

    private static func makeReviewEntry(_ word: String, kgCardId: String? = nil) -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: word,
            translation: "t-\(word)",
            context: "\(word) context",
            bookTitle: "Test"
        )
        entry.kgCardId = kgCardId
        return entry
    }
}
