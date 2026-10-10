import Foundation
import Testing
@testable import BooksAndVocab

/// Backend caps batch add/delete/archive at 500 items per request (#2472).
/// `KGService` has no URLSession seam, so the chunking runner and the response
/// mergers are pinned as pure functions that the three batch methods share.
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
