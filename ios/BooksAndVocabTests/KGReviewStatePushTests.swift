import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Review-state push (#2483). The acknowledgement covers only what was sent,
/// and no `PATCH api/vocab/review` carries more entries than the backend's
/// 5000-entry cap allows.
@MainActor
struct KGReviewStatePushTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            VocabularyEntry.self,
            ReviewRecord.self,
            Notebook.self,
            Book.self,
            PodcastSeries.self,
            PodcastEpisode.self,
            PodcastProgress.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func seedSyncedEntries(_ count: Int, in container: ModelContainer, reviewedAt: Date?) throws {
        let context = ModelContext(container)
        for index in 0..<count {
            let entry = VocabularyEntry(word: "w\(index)", translation: "t", context: "c", bookTitle: "b")
            entry.markSynced()
            entry.lastReviewedAt = reviewedAt
            context.insert(entry)
        }
        try context.save()
    }

    private func makeService(_ transport: ReviewPushRecordingTransport) -> KGService {
        KGService(
            authSession: ReviewPushFixedAuthSession(),
            sessionInvalidator: ReviewPushNoopInvalidator(),
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }

    private func entryCounts(_ transport: ReviewPushRecordingTransport) throws -> [Int] {
        try transport.requests.map { request in
            let data = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(json["entries"] as? [Any]).count
        }
    }

    // MARK: - Lost update

    /// A review persisted after the batch was built must stay dirty after the
    /// ack. Its `lastReviewedAt` is set to a point the old wall-clock boundary
    /// would have covered, so only the sent-instant ack keeps it dirty.
    @Test func reviewSavedDuringThePatchStaysDirtyAfterTheAck() async throws {
        let container = try makeContainer()
        // Both instants precede the ack's wall clock: the old boundary ack covered them.
        let sentReview = Date().addingTimeInterval(-3600)
        try seedSyncedEntries(1, in: container, reviewedAt: sentReview)

        let transport = ReviewPushRecordingTransport(responseBody: #"{"updated":1,"skipped":0}"#)
        transport.onRequest = { _ in
            let writer = ModelContext(container)
            guard let entry = try? writer.fetch(FetchDescriptor<VocabularyEntry>()).first else { return }
            entry.lastReviewedAt = sentReview.addingTimeInterval(30)
            try? writer.save()
        }

        _ = try await makeService(transport).pushReviewStates(container: container)

        #expect(transport.requests.count == 1)
        #expect(try await BackgroundSyncActor(modelContainer: container).buildReviewStatePushPayload().count == 1)
    }

    // MARK: - Batching

    @Test func dirtyCardsGoOutInBatchesOf1000() async throws {
        let container = try makeContainer()
        try seedSyncedEntries(2501, in: container, reviewedAt: nil)

        let transport = ReviewPushRecordingTransport(responseBody: #"{"updated":1000,"skipped":0}"#)
        _ = try await makeService(transport).pushReviewStates(container: container)

        #expect(transport.requests.map { $0.url?.path } == Array(repeating: "/api/vocab/review", count: 3))
        #expect(transport.requests.allSatisfy { $0.httpMethod == "PATCH" })
        #expect(try entryCounts(transport) == [1000, 1000, 501])
        #expect(try await BackgroundSyncActor(modelContainer: container).buildReviewStatePushPayload().isEmpty)
    }

    /// A 422 on the second batch rejects that request whole. The first batch
    /// landed and must stay acknowledged; the other 1001 cards stay dirty.
    @Test func rejectedSecondBatchKeepsTheFirstAckedAndTheRestDirty() async throws {
        let container = try makeContainer()
        try seedSyncedEntries(2001, in: container, reviewedAt: nil)

        let transport = ReviewPushRecordingTransport(
            responseBody: #"{"updated":1000,"skipped":0}"#,
            failingRequestNumber: 2
        )
        await #expect(throws: KGError.self) {
            _ = try await makeService(transport).pushReviewStates(container: container)
        }

        #expect(transport.requests.count == 2)
        #expect(try await BackgroundSyncActor(modelContainer: container).buildReviewStatePushPayload().count == 1001)
    }

    // MARK: - Card preference PATCH (#2042 stage 2)

    /// Minimal `KGCard` body the preferences PATCH decodes into.
    private static let cardResponseJSON = #"{"id":"c1","content":"deft","meaning":"靈巧的","pos":null,"difficulty":null,"difficultyTier":null,"note":null,"collocations":[],"examples":["an example"],"mode":"production","isDeleted":false,"isArchived":false,"notebookId":"default"}"#

    private func patchBody(_ transport: ReviewPushRecordingTransport) throws -> [String: Any] {
        let data = try #require(transport.requests.first?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Converting a card's direction is a mode-only PATCH. It must send just
    /// `{"mode": ...}` and must not trip the at-least-one-preference precondition.
    @Test func modeOnlyPreferencesPatchSendsOnlyTheMode() async throws {
        let transport = ReviewPushRecordingTransport(responseBody: Self.cardResponseJSON)
        _ = try await makeService(transport).updateCardPreferences(
            word: "deft", readerHidden: nil, reviewExcluded: nil, mode: .production, notebookId: "default"
        )

        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.httpMethod == "PATCH")
        #expect(transport.requests.first?.url?.path == "/api/vocab/deft/preferences")
        let body = try patchBody(transport)
        #expect(body.keys.sorted() == ["mode"])
        #expect(body["mode"] as? String == "production")
    }

    /// Guards the existing reader-hidden PATCH: an omitted field stays off the wire.
    @Test func readerHiddenPatchStillSendsOnlyThatField() async throws {
        let transport = ReviewPushRecordingTransport(responseBody: Self.cardResponseJSON)
        _ = try await makeService(transport).updateCardPreferences(
            word: "deft", readerHidden: true, reviewExcluded: nil, notebookId: "default"
        )

        #expect(try patchBody(transport).keys.sorted() == ["reader_hidden"])
    }

    /// A mode the user set locally is pushed as a mode-only preferences PATCH.
    /// The flag clears only after the server answers, so a failed push retries.
    @Test func pendingReviewModeIsSentViaUpdateCardPreferences() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "deft", translation: "t", context: "c", bookTitle: "b")
        entry.markSynced()
        entry.kgCardId = "c1"
        entry.requestReviewMode(.production)
        context.insert(entry)
        try context.save()

        let transport = ReviewPushRecordingTransport(responseBody: Self.cardResponseJSON)
        try await makeService(transport).pushPendingReviewModes(container: container)

        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.url?.path == "/api/vocab/deft/preferences")
        let body = try patchBody(transport)
        #expect(body.keys.sorted() == ["mode"])
        #expect(body["mode"] as? String == "production")
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<VocabularyEntry>()).first)
        #expect(stored.pendingReviewModePush == false)
    }
}

/// Recording transport for the review-state PATCH. `onRequest` runs inside the
/// request, which is how a test lands a review while the batch is in flight.
private final class ReviewPushRecordingTransport: KGHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responseBody: String
    private let failingRequestNumber: Int?
    private var recorded: [URLRequest] = []
    private var hook: (@Sendable (Int) -> Void)?

    var requests: [URLRequest] { lock.withLock { recorded } }

    var onRequest: (@Sendable (Int) -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    init(responseBody: String, failingRequestNumber: Int? = nil) {
        self.responseBody = responseBody
        self.failingRequestNumber = failingRequestNumber
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (number, observer) = lock.withLock { () -> (Int, (@Sendable (Int) -> Void)?) in
            recorded.append(request)
            return (recorded.count, hook)
        }
        observer?(number)
        let failing = number == failingRequestNumber
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: failing ? 422 : 200, httpVersion: nil, headerFields: nil)
        )
        return (Data((failing ? #"{"detail":"bad"}"# : responseBody).utf8), response)
    }
}

@MainActor
private final class ReviewPushFixedAuthSession: AuthSessionProviding {
    let isLoggedIn = true
    let token: String? = "header.eyJleHAiOjQxMzg2Njg0MDB9.signature"
}

@MainActor
private final class ReviewPushNoopInvalidator: SessionInvalidating {
    func logout(modelContainer: SwiftData.ModelContainer?, reason: String) {}
    func waitForPendingLocalDataCleanup() async {}
}
