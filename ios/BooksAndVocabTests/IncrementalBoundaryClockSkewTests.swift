//
//  IncrementalBoundaryClockSkewTests.swift
//  Books & Vocab Tests
//
//  #2426 — the incremental pull boundary was the device clock, but the server
//  compares it with its own `updated_at`. A device running ahead pushed the
//  boundary past server time, so changes made elsewhere inside that gap were
//  never pulled again. The boundary now follows the earlier of the device clock
//  and the server `Date` header, minus a margin.
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
struct IncrementalBoundaryClockSkewTests {

    private let boundaryKey = KGService.SyncKeys.incrementalBoundary
    private let payloadVersionKey = KGService.SyncKeys.payloadVersion

    // MARK: - Boundary anchoring

    /// Device clock 10 minutes ahead of the server: the boundary must follow
    /// server time, not the device, or the 10-minute gap hides server changes.
    @Test func deviceAheadOfServer_boundaryFollowsServerDate() async throws {
        let container = try VocabPullHarness.makeContainer()
        let defaults = VocabPullHarness.makeDefaults()
        let serverDate = Date().addingTimeInterval(-600)
        let transport = DatedVocabTransport(
            serverDate: serverDate,
            cards: [ServedVocabCard(id: "c1", content: "w1", updatedAt: serverDate)]
        )
        let service = makeService(transport)

        _ = try await service.pullCardsToLocal(
            container: container, progress: nil, notebookId: nil, reporter: nil, defaults: defaults
        )

        let boundary = defaults.double(forKey: boundaryKey)
        #expect(boundary > 0)
        #expect(boundary <= serverDate.timeIntervalSince1970 - 60,
                "boundary sits inside the device-ahead gap, so server changes in that window are skipped")
    }

    /// Device clock 10 minutes behind the server: the boundary must still stay
    /// at or below the device's own clock minus the margin. Nothing it was
    /// sampled from may run ahead of the device.
    /// Also red on origin/main: the bare device clock carries no 60 s margin, so
    /// the boundary sits above `clientNowAfterPull - 60` unless the pull takes a minute.
    @Test func deviceBehindServer_boundaryStaysBelowClientNow() async throws {
        let container = try VocabPullHarness.makeContainer()
        let defaults = VocabPullHarness.makeDefaults()
        let serverDate = Date().addingTimeInterval(600)
        let transport = DatedVocabTransport(
            serverDate: serverDate,
            cards: [ServedVocabCard(id: "c1", content: "w1", updatedAt: serverDate)]
        )
        let service = makeService(transport)

        _ = try await service.pullCardsToLocal(
            container: container, progress: nil, notebookId: nil, reporter: nil, defaults: defaults
        )

        let clientNowAfterPull = Date().timeIntervalSince1970
        let boundary = defaults.double(forKey: boundaryKey)
        #expect(boundary > 0)
        #expect(boundary <= clientNowAfterPull - 60)
    }

    // MARK: - Overlap is harmless

    /// A row updated 30 s before the server clock lies inside the 60 s margin.
    /// Without the margin the boundary would equal server time, the `since`
    /// filter would skip the row, and the second pull would serve nothing.
    /// With the margin the row is served again and must merge without a duplicate.
    @Test func rowInsideMarginIsReReadAndMergesOnce() async throws {
        let container = try VocabPullHarness.makeContainer()
        let defaults = VocabPullHarness.makeDefaults()
        let serverDate = Date()
        let transport = DatedVocabTransport(
            serverDate: serverDate,
            cards: [ServedVocabCard(id: "c-edge", content: "edge", updatedAt: serverDate.addingTimeInterval(-30))]
        )
        let service = makeService(transport)

        let first = try await service.pullCardsToLocal(
            container: container, progress: nil, notebookId: nil, reporter: nil, defaults: defaults
        )
        #expect(first.inserted == 1)

        // The second pull is incremental and the server returns the same row again.
        let second = try await service.pullCardsToLocal(
            container: container, progress: nil, notebookId: nil, reporter: nil, defaults: defaults
        )

        let sinceValues = transport.vocabRequests.map { vocabQueryValue($0, "since") }
        #expect(sinceValues.count == 2)
        #expect(sinceValues[0] == nil)
        #expect(sinceValues[1] != nil, "second pull must be incremental")
        #expect(transport.servedCounts == [1, 1], "the margin-window row must be served again by the incremental pull")
        #expect(second.inserted == 0)
        let entries = try ModelContext(container).fetch(FetchDescriptor<VocabularyEntry>())
        #expect(entries.count == 1, "re-read row duplicated instead of merging")
    }

    // MARK: - Boundaries written before the anchoring fix

    /// A v1 boundary can already run ahead of server time, because the device
    /// clock wrote it. Bumping the payload version to 2 must make the next pull a
    /// full drain that rebuilds the boundary, not replay the future value as
    /// `since`. A synced entry is seeded so the empty-store guard cannot force a
    /// full sync on its own: without the bump this test is red.
    @Test func staleFutureBoundaryFromPayloadV1_forcesOneFullDrain() async throws {
        let container = try VocabPullHarness.makeContainer()
        let context = ModelContext(container)
        let seeded = VocabularyEntry(word: "gap", translation: "m", context: "c", bookTitle: "B")
        seeded.kgCardId = "c-gap"
        seeded.markSynced()
        context.insert(seeded)
        try context.save()

        let defaults = VocabPullHarness.makeDefaults()
        let serverDate = Date()
        defaults.set(serverDate.addingTimeInterval(600).timeIntervalSince1970, forKey: boundaryKey)
        defaults.set(1, forKey: payloadVersionKey)
        let transport = DatedVocabTransport(
            serverDate: serverDate,
            cards: [ServedVocabCard(id: "c-gap", content: "gap", updatedAt: serverDate.addingTimeInterval(-300))]
        )
        let service = makeService(transport)

        _ = try await service.pullCardsToLocal(
            container: container, progress: nil, notebookId: nil, reporter: nil, defaults: defaults
        )

        let sinceValues = transport.vocabRequests.map { vocabQueryValue($0, "since") }
        #expect(sinceValues == [nil], "a v1 boundary ahead of server time must not be replayed as since")
        #expect(defaults.integer(forKey: payloadVersionKey) == KGService.SyncKeys.currentPayloadVersion)
        let boundary = defaults.double(forKey: boundaryKey)
        #expect(boundary > 0)
        #expect(boundary <= serverDate.timeIntervalSince1970 - 60)
    }

    // MARK: - Helpers

    private func makeService(_ transport: DatedVocabTransport) -> KGService {
        KGService(
            authSession: PullTestAuthSession(),
            sessionInvalidator: PullTestSessionInvalidator(),
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }
}

/// One card as the server serves it: its JSON body plus the server-side
/// `updatedAt` that the incremental `since` filter compares against.
struct ServedVocabCard {
    let updatedAt: Date
    let json: String

    init(id: String, content: String, updatedAt: Date) {
        self.updatedAt = updatedAt
        let stamp = AppDateFormatters.iso8601.string(from: updatedAt)
        json = #"{"id":"\#(id)","content":"\#(content)","meaning":"m-\#(content)","examples":[],"mode":"recognition","isDeleted":false,"notebookId":"default","updatedAt":"\#(stamp)"}"#
    }
}

/// Serves the same `/api/vocab` page on every request, with a `Date` header
/// that stands in for the server clock. Like the server, a request carrying
/// `since` only gets cards with `updatedAt` strictly after it. Records each
/// request and how many cards each response carried.
final class DatedVocabTransport: KGHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let serverDate: Date
    private let cards: [ServedVocabCard]
    private var recorded: [URLRequest] = []
    private var served: [Int] = []

    init(serverDate: Date, cards: [ServedVocabCard]) {
        self.serverDate = serverDate
        self.cards = cards
    }

    var vocabRequests: [URLRequest] { lock.withLock { recorded } }
    var servedCounts: [Int] { lock.withLock { served } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.path.hasSuffix("/api/vocab") else {
            let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 404,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(#"{"detail":"not stubbed"}"#.utf8), response)
        }
        let since = vocabQueryValue(request, "since").flatMap(AppDateFormatters.parseISO8601)
        let visible = cards.filter { card in since.map { card.updatedAt > $0 } ?? true }
        lock.withLock {
            recorded.append(request)
            served.append(visible.count)
        }
        let headers = [
            "Content-Type": "application/json",
            "X-Pipeline-Pending": "false",
            "Date": Self.httpDate(serverDate),
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return (Data(("[" + visible.map(\.json).joined(separator: ",") + "]").utf8), response)
    }

    /// IMF-fixdate, the form a real server writes in its `Date` header.
    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
