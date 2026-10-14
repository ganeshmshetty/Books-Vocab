import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// #3806 — a sync round that started under one session must not write after the session
/// boundary moved (logout or account switch). The boundary is simulated by `endSession()`,
/// which bumps the same counter `AuthManager.endSession` bumps.
@MainActor
struct PullSessionEpochTests {

    /// Logout while the vocab page is on the wire: the response arrives after the boundary,
    /// so its cards belong to the previous account and nothing may be merged or cursored.
    @Test func logoutWhilePageIsInFlightDropsThePullWithoutWriting() async throws {
        let container = try VocabPullHarness.makeContainer()
        let defaults = VocabPullHarness.makeDefaults()
        let session = EpochAuthSession()
        let transport = HeldFirstRequestTransport()
        let service = Self.makeService(session: session, transport: transport)

        let pull = Task {
            try await service.pullCardsToLocal(
                container: container, progress: nil, notebookId: nil, reporter: nil, defaults: defaults
            )
        }
        await transport.waitUntilHeld()
        session.endSession()
        transport.releaseHeld(body: "[\(vocabCardJSON(id: "c1", content: "w1")),\(vocabCardJSON(id: "c2", content: "w2"))]")

        await #expect(throws: CancellationError.self) {
            _ = try await pull.value
        }
        #expect(try VocabPullHarness.words(in: container).isEmpty,
                "a discarded round must not merge the previous account's cards")
        #expect(defaults.object(forKey: KGService.SyncKeys.incrementalBoundary) == nil,
                "the boundary must not advance for a discarded round")
        #expect(defaults.object(forKey: KGService.SyncKeys.payloadVersion) == nil,
                "the payload version must not be stamped for a discarded round")
    }

    /// Logout while the first review-event batch is in flight: the batch's acknowledgement
    /// is dropped and no second batch may leave under the new session's token.
    @Test func logoutBetweenReviewEventBatchesStopsTheDrain() async throws {
        let container = try VocabPullHarness.makeContainer()
        try Self.seedUnpushedReviews(1001, in: container)
        let session = EpochAuthSession()
        let transport = HeldFirstRequestTransport()
        let service = Self.makeService(session: session, transport: transport)

        let push = Task {
            try await service.pushReviewEvents(container: container)
        }
        await transport.waitUntilHeld()
        session.endSession()
        transport.releaseHeld(body: #"{"inserted":1000,"skipped":0}"#)

        await #expect(throws: CancellationError.self) {
            _ = try await push.value
        }
        #expect(transport.requests.count == 1, "no later batch may be sent after the session boundary moved")
        let pending = try await BackgroundSyncActor(modelContainer: container)
            .buildReviewEventsPushPayload().count
        #expect(pending == 1001, "nothing from the discarded session may be acknowledged")
    }

    private static func makeService(session: EpochAuthSession, transport: HeldFirstRequestTransport) -> KGService {
        KGService(
            authSession: session,
            sessionInvalidator: PullTestSessionInvalidator(),
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }

    private static func seedUnpushedReviews(_ count: Int, in container: ModelContainer) throws {
        let context = ModelContext(container)
        for index in 0..<count {
            let record = ReviewRecord(word: "w\(index)", entryID: nil, feedback: 1)
            record.kgCardId = "c\(index)"
            context.insert(record)
        }
        try context.save()
    }
}

/// Session stand-in whose epoch the test moves, as a logout would.
@MainActor
private final class EpochAuthSession: AuthSessionProviding {
    let isLoggedIn = true
    let token: String? = "header.eyJleHAiOjQxMzg2Njg0MDB9.signature"
    private(set) var sessionEpoch = 0

    func endSession() {
        sessionEpoch += 1
    }
}

/// Holds the first request until the test releases it. Later requests are answered at once:
/// a review-event PATCH gets an `inserted` count equal to its batch, anything else an empty page.
private final class HeldFirstRequestTransport: KGHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var held: CheckedContinuation<(Data, URLResponse), Error>?
    private var heldURL: URL?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    var requests: [URLRequest] { lock.withLock { sent } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = lock.withLock { () -> Int in
            sent.append(request)
            return sent.count
        }
        guard index == 1 else {
            return Self.respond(url: request.url ?? Self.fallbackURL, body: Self.insertedBody(for: request))
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                held = continuation
                heldURL = request.url
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if held != nil { return true }
                heldWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func releaseHeld(body: String) {
        let (continuation, url) = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), Error>?, URL?) in
            let taken = (held, heldURL)
            held = nil
            return taken
        }
        continuation?.resume(returning: Self.respond(url: url ?? Self.fallbackURL, body: body))
    }

    private static let fallbackURL = URL(string: "https://kg.test/api")!

    private static func insertedBody(for request: URLRequest) -> String {
        let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let count = (object?["entries"] as? [Any])?.count ?? 0
        return #"{"inserted":\#(count),"skipped":0}"#
    }

    private static func respond(url: URL, body: String) -> (Data, URLResponse) {
        let headers = ["Content-Type": "application/json", "X-Pipeline-Pending": "false"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }
}
