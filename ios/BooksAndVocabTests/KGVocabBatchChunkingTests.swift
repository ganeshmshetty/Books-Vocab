import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Backend caps batch add/delete/archive at 500 items per request (#2472).
/// The chunking runner and response mergers are pinned as pure functions; the
/// wiring of the three batch methods is pinned through a recording transport.
struct KGVocabBatchChunkingTests {

    @Test func chunkLimitMatchesBackendCap() {
        #expect(KGService.maxVocabBatchSize == 500)
    }

    @Test func splitsIntoRequestsNoLargerThanCap() async throws {
        let items = Array(0..<1201)
        var sizes: [Int] = []
        let total: Int = try await KGService.performChunked(items) { chunk in
            sizes.append(chunk.count)
            return chunk.count
        } merge: { $0 + $1 }
        #expect(sizes == [500, 500, 201])
        #expect(total == 1201)
    }

    @Test func exactlyCapIsSingleRequest() async throws {
        var calls = 0
        _ = try await KGService.performChunked(Array(0..<500)) { chunk -> Int in
            calls += 1
            return chunk.count
        } merge: { $0 + $1 }
        #expect(calls == 1)
    }

    @Test func emptyInputStillSendsOnceToKeepLegacyBehaviour() async throws {
        var calls = 0
        _ = try await KGService.performChunked([Int]()) { chunk -> Int in
            calls += 1
            return chunk.count
        } merge: { $0 + $1 }
        #expect(calls == 1)
    }

    @Test func failureInLaterChunkPropagates() async {
        struct Boom: Error {}
        var calls = 0
        do {
            _ = try await KGService.performChunked(Array(0..<1001)) { chunk -> Int in
                calls += 1
                if calls == 2 { throw Boom() }
                return chunk.count
            } merge: { $0 + $1 }
            Issue.record("expected throw")
        } catch {
            #expect(error is Boom)
            #expect(calls == 2)
        }
    }

    @Test func mergesAddResponses() {
        let a = KGAddResponse(created: 2, skipped: 1, duplicates: ["x"], cardIds: ["a": "1"])
        let b = KGAddResponse(created: 3, skipped: 0, duplicates: ["y"], cardIds: ["b": "2"])
        let m = KGService.merged(a, b)
        #expect(m.created == 5)
        #expect(m.skipped == 1)
        #expect(m.duplicates == ["x", "y"])
        #expect(m.cardIds == ["a": "1", "b": "2"])
    }

    @Test func mergesDeleteAndArchiveResponses() {
        let d = KGService.merged(
            KGBatchDeleteResponse(deleted: 1, deleted_words: ["a"], not_found: []),
            KGBatchDeleteResponse(deleted: 1, deleted_words: ["b"], not_found: ["c"])
        )
        #expect(d.deleted == 2)
        #expect(d.deleted_words == ["a", "b"])
        #expect(d.not_found == ["c"])
        let r = KGService.merged(
            KGBatchArchiveResponse(updated: 1, updated_words: ["a"], not_found: ["z"]),
            KGBatchArchiveResponse(updated: 2, updated_words: ["b", "c"], not_found: [])
        )
        #expect(r.updated == 3)
        #expect(r.updated_words == ["a", "b", "c"])
        #expect(r.not_found == ["z"])
    }
}

@MainActor
struct KGVocabBatchWiringTests {
    private func makeService(_ transport: ChunkRecordingTransport) -> KGService {
        KGService(
            authSession: ChunkFixedAuthSession(),
            sessionInvalidator: ChunkNoopInvalidator(),
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }

    private func bodyArray(_ request: URLRequest) throws -> [Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
    }

    private func bodyWords(_ request: URLRequest) throws -> [String] {
        let data = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["words"] as? [String])
    }

    @Test func batchAddSplitsAt500() async throws {
        let transport = ChunkRecordingTransport(responseBody: #"{"created":1,"skipped":0,"duplicates":[],"cardIds":{}}"#)
        let entries = (0..<1201).map { VocabularyEntry(word: "w\($0)", translation: "t", context: "c", bookTitle: "b") }

        let response = try await makeService(transport).batchAdd(entries: entries, notebookId: "nb")

        #expect(transport.requests.map { $0.url?.path } == Array(repeating: "/api/vocab", count: 3))
        #expect(transport.requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(try transport.requests.map { try bodyArray($0).count } == [500, 500, 201])
        #expect(response.created == 3)
    }

    @Test func batchAddAtCapIsOneRequest() async throws {
        let transport = ChunkRecordingTransport(responseBody: #"{"created":500,"skipped":0,"duplicates":[],"cardIds":{}}"#)
        let entries = (0..<500).map { VocabularyEntry(word: "w\($0)", translation: "t", context: "c", bookTitle: "b") }

        _ = try await makeService(transport).batchAdd(entries: entries, notebookId: "nb")

        #expect(transport.requests.count == 1)
        #expect(try bodyArray(transport.requests[0]).count == 500)
    }

    @Test func batchDeleteSplitsAt500() async throws {
        let transport = ChunkRecordingTransport(responseBody: #"{"deleted":0,"deleted_words":[],"not_found":[]}"#)
        let words = (0..<1001).map { "w\($0)" }

        _ = try await makeService(transport).batchDeleteCards(words: words, notebookId: "nb")

        #expect(transport.requests.map { $0.url?.path } == Array(repeating: "/api/vocab/batch-delete", count: 3))
        #expect(try transport.requests.map { try bodyWords($0).count } == [500, 500, 1])
    }

    @Test func batchArchiveSplitsAt500AndKeepsArchivedFlag() async throws {
        let transport = ChunkRecordingTransport(responseBody: #"{"updated":0,"updated_words":[],"not_found":[]}"#)
        let words = (0..<1001).map { "w\($0)" }

        _ = try await makeService(transport).batchArchiveCards(words: words, archived: true, notebookId: "nb")

        #expect(transport.requests.map { $0.url?.path } == Array(repeating: "/api/vocab/batch-archive", count: 3))
        #expect(try transport.requests.map { try bodyWords($0).count } == [500, 500, 1])
        for request in transport.requests {
            let data = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["archived"] as? Bool == true)
        }
    }

    @Test func batchDeleteAndArchiveAtCapAreOneRequestEach() async throws {
        let deleteTransport = ChunkRecordingTransport(responseBody: #"{"deleted":0,"deleted_words":[],"not_found":[]}"#)
        _ = try await makeService(deleteTransport).batchDeleteCards(words: (0..<500).map { "w\($0)" }, notebookId: "nb")
        #expect(deleteTransport.requests.count == 1)

        let archiveTransport = ChunkRecordingTransport(responseBody: #"{"updated":0,"updated_words":[],"not_found":[]}"#)
        _ = try await makeService(archiveTransport).batchArchiveCards(words: (0..<500).map { "w\($0)" }, archived: false, notebookId: "nb")
        #expect(archiveTransport.requests.count == 1)
    }

    @Test func failingSecondChunkSendsNoThirdRequest() async throws {
        let transport = ChunkRecordingTransport(
            responseBody: #"{"deleted":0,"deleted_words":[],"not_found":[]}"#,
            failingRequestNumber: 2
        )
        await #expect(throws: KGError.self) {
            _ = try await makeService(transport).batchDeleteCards(words: (0..<1201).map { "w\($0)" }, notebookId: "nb")
        }
        #expect(transport.requests.count == 2)
    }
}

@MainActor
private final class ChunkFixedAuthSession: AuthSessionProviding {
    let isLoggedIn = true
    let token: String? = "header.eyJleHAiOjQxMzg2Njg0MDB9.signature"
}

@MainActor
private final class ChunkNoopInvalidator: SessionInvalidating {
    func logout(modelContainer: SwiftData.ModelContainer?, reason: String) {}
    func waitForPendingLocalDataCleanup() async {}
}

private final class ChunkRecordingTransport: KGHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responseBody: String
    private let failingRequestNumber: Int?
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    init(responseBody: String, failingRequestNumber: Int? = nil) {
        self.responseBody = responseBody
        self.failingRequestNumber = failingRequestNumber
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let number = lock.withLock {
            recorded.append(request)
            return recorded.count
        }
        let failing = number == failingRequestNumber
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: failing ? 422 : 200, httpVersion: nil, headerFields: nil)
        )
        return (Data((failing ? #"{"detail":"bad"}"# : responseBody).utf8), response)
    }
}
