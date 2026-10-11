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

    // MARK: - Boundary anchoring

    /// Device clock 10 minutes ahead of the server: the boundary must follow
    /// server time, not the device, or the 10-minute gap hides server changes.
    @Test func deviceAheadOfServer_boundaryFollowsServerDate() async throws {
        let container = try VocabPullHarness.makeContainer()
        let defaults = VocabPullHarness.makeDefaults()
        let serverDate = Date().addingTimeInterval(-600)
        let transport = DatedVocabTransport(serverDate: serverDate, cards: [vocabCardJSON(id: "c1", content: "w1")])
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
    @Test func deviceBehindServer_boundaryStaysBelowClientNow() async throws {
        let container = try VocabPullHarness.makeContainer()
        let defaults = VocabPullHarness.makeDefaults()
        let transport = DatedVocabTransport(
            serverDate: Date().addingTimeInterval(600),
            cards: [vocabCardJSON(id: "c1", content: "w1")]
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

    /// A row inside the margin window is re-read by the next incremental pull
    /// and must merge into the existing entry without a duplicate.
    @Test func rowInsideMarginIsReReadAndMergesOnce() async throws {
        let container = try VocabPullHarness.makeContainer()
        let defaults = VocabPullHarness.makeDefaults()
        let transport = DatedVocabTransport(
            serverDate: Date(),
            cards: [vocabCardJSON(id: "c-edge", content: "edge")]
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
        #expect(second.inserted == 0)
        let entries = try ModelContext(container).fetch(FetchDescriptor<VocabularyEntry>())
        #expect(entries.count == 1, "re-read row duplicated instead of merging")
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

/// Serves the same `/api/vocab` page on every request, with a `Date` header
/// that stands in for the server clock. Records each request.
final class DatedVocabTransport: KGHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let serverDate: Date
    private let cards: [String]
    private var recorded: [URLRequest] = []

    init(serverDate: Date, cards: [String]) {
        self.serverDate = serverDate
        self.cards = cards
    }

    var vocabRequests: [URLRequest] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.path.hasSuffix("/api/vocab") else {
            let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 404,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(#"{"detail":"not stubbed"}"#.utf8), response)
        }
        lock.withLock { recorded.append(request) }
        let headers = [
            "Content-Type": "application/json",
            "X-Pipeline-Pending": "false",
            "Date": Self.httpDate(serverDate),
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return (Data(("[" + cards.joined(separator: ",") + "]").utf8), response)
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
