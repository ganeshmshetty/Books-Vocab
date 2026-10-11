//
//  PodcastSubtitleFetchStatusTests.swift
//
//  #2106: a non-2xx subtitle response (503 / 404 with a JSON body) must
//  resolve to `.failed` (retry offered), not `.content(<error body>)` that
//  parses to zero cues and reads as "此集無逐句字幕" with no retry.
//  Exercises the real fetch path over a URLProtocol stub.
//

#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@Suite("Podcast subtitle fetch HTTP status")
struct PodcastSubtitleFetchStatusTests {

    @Test(arguments: [503, 404, 401])
    func errorStatusResolvesToFailed(status: Int) async {
        let session = SubtitleStatusURLProtocol.makeSession()
        let subtitle = await PodcastPlayerLoader.resolveSubtitle(
            from: .remote(SubtitleStatusURLProtocol.url(status: status)),
            kgService: SubtitleStubTokenProvider()
        ) { urlString, kgService in
            await PodcastPlayerLoader.fetchSubtitle(
                urlString: urlString, kgService: kgService, session: session
            )
        }

        #expect(subtitle == .failed)
    }

    @Test func errorStatusFetchReturnsNilForRetryPath() async {
        let subtitle = await PodcastPlayerLoader.fetchSubtitle(
            urlString: SubtitleStatusURLProtocol.url(status: 503),
            kgService: SubtitleStubTokenProvider(),
            session: SubtitleStatusURLProtocol.makeSession()
        )

        #expect(subtitle == nil)
    }

    /// Positive control: the same stub path still delivers a 200 SRT body,
    /// so the `.failed` assertions above cannot pass vacuously.
    @Test func successStatusDeliversSubtitleContent() async {
        let session = SubtitleStatusURLProtocol.makeSession()
        let subtitle = await PodcastPlayerLoader.resolveSubtitle(
            from: .remote(SubtitleStatusURLProtocol.url(status: 200)),
            kgService: SubtitleStubTokenProvider()
        ) { urlString, kgService in
            await PodcastPlayerLoader.fetchSubtitle(
                urlString: urlString, kgService: kgService, session: session
            )
        }

        #expect(subtitle == .content(SubtitleStatusURLProtocol.srtBody))
    }

    @Test func authedDataThrowsOnNonSuccessStatus() async {
        await #expect(throws: URLError.self) {
            _ = try await PodcastSyncService.authedData(
                from: SubtitleStatusURLProtocol.url(status: 503),
                kgService: SubtitleStubTokenProvider(),
                session: SubtitleStatusURLProtocol.makeSession()
            )
        }
    }
}

/// Stateless stub: the status to answer with is encoded in the request URL
/// (`?status=N`), so concurrent tests never share mutable state. 2xx answers
/// with an SRT body; anything else with a JSON error body.
private final class SubtitleStatusURLProtocol: URLProtocol {
    static let srtBody = "1\n00:00:00,000 --> 00:00:01,000\nHello there.\n"

    static func url(status: Int) -> String {
        "https://podcast.test/api/podcasts/series_a/1/subtitle?status=\(status)"
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleStatusURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "podcast.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "status" })?.value
            .flatMap(Int.init) ?? 200
        let isSuccess = (200..<300).contains(status)
        let body = isSuccess ? Self.srtBody : #"{"detail":"Service Unavailable"}"#
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": isSuccess ? "application/x-subrip" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SubtitleStubTokenProvider: AuthTokenProviding {
    func currentAuthToken() async throws -> String { "token" }
    func authTokenWithoutInvalidation() async -> String? { "token" }
    func handleUnauthorized(modelContainer: ModelContainer?, reason: String) async {}
}
#endif
