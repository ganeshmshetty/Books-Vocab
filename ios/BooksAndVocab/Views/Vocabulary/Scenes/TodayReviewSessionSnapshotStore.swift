import Foundation

struct TodayReviewSessionSnapshotStore {
    private static let defaultsKey = "kg.review.activeSession.v1"
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    struct Snapshot: Codable {
        struct QueueItem: Codable {
            let persistenceID: String
            let baseline: ReviewBaseline
        }

        struct SubmittedAnswer: Codable {
            let feedbackRaw: Int
            let answeredAt: Date
            let reviewRecordID: UUID
            /// Whether the DB flush (reviewCount/nextReviewAt/streak update +
            /// ReviewRecord insert) confirmed success for this answer. Restore
            /// re-flushes any answer left `false` so a failed background flush
            /// (DB error / entry missing) can't strand the card's schedule while
            /// the UI shows it as reviewed.
            let flushed: Bool

            init(feedbackRaw: Int, answeredAt: Date, reviewRecordID: UUID, flushed: Bool) {
                self.feedbackRaw = feedbackRaw
                self.answeredAt = answeredAt
                self.reviewRecordID = reviewRecordID
                self.flushed = flushed
            }

            // Backward compat: legacy blobs predate `flushed`. Those answers
            // were already flushed (the bug is a rare flush failure), so a
            // missing key decodes to `true` — never re-flush historical data.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                feedbackRaw = try c.decode(Int.self, forKey: .feedbackRaw)
                answeredAt = try c.decode(Date.self, forKey: .answeredAt)
                reviewRecordID = try c.decode(UUID.self, forKey: .reviewRecordID)
                flushed = try c.decodeIfPresent(Bool.self, forKey: .flushed) ?? true
            }
        }

        let userId: String
        let sessionStartTime: Date
        let currentIndex: Int
        let queue: [QueueItem]
        let submissions: [Int: SubmittedAnswer]
        let updatedAt: Date
    }

    struct ReviewBaseline: Codable {
        let reviewIntervalHours: Double
        let nextReviewAt: Date
        let lastReviewedAt: Date?
        let reviewCount: Int
        let lapseCount: Int
        let reviewStreak: Int
        let lastReviewFeedbackRaw: Int
    }

    // MARK: - Public API

    /// Per-flip submit calls `save()` synchronously inside the SwiftUI
    /// transaction. The old full decode→mutate→encode→defaults-write roundtrip
    /// measured ~65ms of main-thread stall per flip on device Release
    /// (review_flip_probe time-profile). This store is the single funnel for
    /// the defaults key, so a queue-confined cache kills the repeated decode
    /// and the serial queue moves encode + write off the caller's thread.
    /// `load`/`save`/`clear` share one FIFO: a save followed by a load always
    /// observes the saved value. Crash window: a snapshot enqueued but not yet
    /// written is lost if the process dies first — bounded by one background
    /// encode (~ms). A loss costs at most that one flip's answer (the user
    /// re-answers one card after restore); it is NOT covered by the restore
    /// reflush, which only repairs answers whose snapshot survived but whose
    /// DB flush never confirmed.
    private static let queue = DispatchQueue(label: "kg.review.snapshotStore", qos: .utility)
    private static var cache: [String: Snapshot]?

    /// Test-only: drop the in-memory cache so the next access re-decodes from
    /// UserDefaults. Without this, tests that seed the defaults key directly
    /// (e.g. legacy-migration blobs) are silently masked by a warm cache.
    static func _invalidateCacheForTesting() {
        queue.sync { cache = nil }
    }

    static func load(for userId: String) -> Snapshot? {
        queue.sync {
            guard let snapshot = loadedStore()[userId] else { return nil }

            guard Date().timeIntervalSince(snapshot.updatedAt) <= maxAge else {
                var store = loadedStore()
                store.removeValue(forKey: userId)
                writeStore(store)
                return nil
            }

            return snapshot
        }
    }

    static func save(_ snapshot: Snapshot) {
        queue.async {
            var store = loadedStore()
            store[snapshot.userId] = snapshot
            writeStore(store)
        }
    }

    /// Passing `nil` clears every user's snapshot; passing a `userId` clears only that user's.
    static func clear(for userId: String?) {
        queue.async {
            guard let userId else {
                cache = [:]
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                return
            }

            var store = loadedStore()
            guard store[userId] != nil else { return }
            store.removeValue(forKey: userId)
            writeStore(store)
        }
    }

    // MARK: - Persistence (queue-confined: only call on `queue`)

    /// Returns the per-user snapshot map, decoding from defaults once and
    /// serving the cache thereafter. Transparently migrates the legacy
    /// single-`Snapshot` payload (pre per-user keying) into the new dictionary.
    private static func loadedStore() -> [String: Snapshot] {
        if let cache { return cache }

        let store: [String: Snapshot]
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            if let decoded = try? JSONDecoder().decode([String: Snapshot].self, from: data) {
                store = decoded
            } else if let legacy = try? JSONDecoder().decode(Snapshot.self, from: data) {
                store = [legacy.userId: legacy]
                writeStore(store)
            } else {
                store = [:]
            }
        } else {
            store = [:]
        }

        cache = store
        return store
    }

    private static func writeStore(_ store: [String: Snapshot]) {
        cache = store
        if store.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
