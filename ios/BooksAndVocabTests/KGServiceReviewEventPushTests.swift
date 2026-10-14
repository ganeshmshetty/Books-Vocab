import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// #3907 — a review saved after a push's payload snapshot must still reach the server in the same
/// session when a second push call arrives while the first is in flight. The second call returns at
/// once; the first must run another round for what was saved after its snapshot, not drop it until
/// the next sync.
@MainActor
struct KGServiceReviewEventPushTests {

    @Test func recordSavedAfterSnapshotIsPushedBeforeTheOuterCallReturns() async throws {
        let container = try VocabPullHarness.makeContainer()
        let recordA = try Self.insertReview(word: "alpha", in: container)
        let transport = BlockingFirstPatchTransport()
        let service = Self.makeService(transport: transport)

        let outer = Task {
            try await service.pushReviewEvents(container: container)
        }
        await transport.waitUntilHeld()

        // Saved after the outer round built its snapshot (which held only A) and while its PATCH is in flight.
        let recordB = try Self.insertReview(word: "beta", in: container)

        let concurrent = try await service.pushReviewEvents(container: container)
        #expect(concurrent.inserted == 0 && concurrent.skipped == 0,
                "the concurrent call defers to the in-flight push and sends nothing itself")
        #expect(transport.requests.count == 1,
                "no PATCH may leave from the concurrent call while the first push holds the claim")

        transport.releaseHeld()
        _ = try await outer.value

        let patches = transport.requests
        try #require(patches.count == 2, "the outer push must run a second round for the record saved after its snapshot")
        #expect(Self.eventIDs(in: patches[0]) == [recordA.uuidString])
        #expect(Self.eventIDs(in: patches[1]) == [recordB.uuidString],
                "the second round must carry exactly B's event")
        #expect(try Self.pushedAt(of: recordB, in: container) != nil,
                "B must be acknowledged before the outer call returns")
    }

    private static func makeService(transport: BlockingFirstPatchTransport) -> KGService {
        KGService(
            authSession: PullTestAuthSession(),
            sessionInvalidator: PullTestSessionInvalidator(),
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }

    @discardableResult
    private static func insertReview(word: String, in container: ModelContainer) throws -> UUID {
        let context = ModelContext(container)
        let record = ReviewRecord(word: word, entryID: nil, feedback: 1)
        record.kgCardId = "card-\(word)"
        context.insert(record)
        try context.save()
        return record.id
    }

    private static func pushedAt(of id: UUID, in container: ModelContainer) throws -> Date? {
        let records = try ModelContext(container).fetch(FetchDescriptor<ReviewRecord>())
        return records.first { $0.id == id }?.pushedAt
    }

    private static func eventIDs(in request: URLRequest) -> [String] {
        let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["event_id"] as? String }
    }
}

/// Holds the first review-event PATCH until the test releases it, so a second push can run during it.
/// Every other request is answered at once: a PATCH gets `inserted` equal to its batch size.
private final class BlockingFirstPatchTransport: KGHTTPTransport, @unchecked Sendable {
    private struct Held {
        let request: URLRequest
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var held: Held?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    var requests: [URLRequest] { lock.withLock { sent } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = lock.withLock { () -> Int in
            sent.append(request)
            return sent.count
        }
        guard index == 1 else {
            return Self.respond(to: request)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                held = Held(request: request, continuation: continuation)
                let waiting = heldWaiter
                heldWaiter = nil
                return waiting
            }
            waiter?.resume()
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

    func releaseHeld() {
        let taken = lock.withLock { () -> Held? in
            defer { held = nil }
            return held
        }
        guard let taken else { return }
        taken.continuation.resume(returning: Self.respond(to: taken.request))
    }

    private static func respond(to request: URLRequest) -> (Data, URLResponse) {
        let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let count = (object?["entries"] as? [Any])?.count ?? 0
        let url = request.url ?? URL(string: "https://kg.test/api")!
        let headers = ["Content-Type": "application/json", "X-Pipeline-Pending": "false"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return (Data(#"{"inserted":\#(count),"skipped":0}"#.utf8), response)
    }
}
