#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@Suite("PodcastPlayerLoader")
struct PodcastPlayerLoaderTests {
    @Test func inlineSubtitlePassesThroughWithoutRemoteFetch() async {
        let subtitle = await PodcastPlayerLoader.resolveSubtitle(
            from: .inline("inline subtitle"),
            kgService: StubAuthTokenProvider()
        ) { _, _ in
            Issue.record("remote subtitle fetch should not run for inline subtitles")
            return nil
        }

        #expect(subtitle == .content("inline subtitle"))
    }

    @Test func remoteSubtitleFailureIsExplicit() async {
        let subtitle = await PodcastPlayerLoader.resolveSubtitle(
            from: .remote("https://example.com/subtitle.srt"),
            kgService: StubAuthTokenProvider()
        ) { _, _ in
            nil
        }

        #expect(subtitle == .failed)
    }

    @Test func unavailableSubtitleStaysUnavailable() async {
        let subtitle = await PodcastPlayerLoader.resolveSubtitle(
            from: .unavailable,
            kgService: StubAuthTokenProvider()
        )

        #expect(subtitle == .unavailable)
    }

    @Test func localAudioNeedsNoAuthHeaderLookup() async throws {
        let episode = makeEpisode()
        episode.localAudioPath = "/tmp/local-audio.m4a"
        let plan = try #require(PodcastPlayerLoadPlan.make(episode: episode, fileExists: { _ in true }))

        let headers = try await PodcastPlayerLoader.resolveAudioHeaders(
            for: plan,
            kgService: StubAuthTokenProvider()
        ) { _ in
            Issue.record("token provider should not run for local audio")
            return "unused"
        }

        #expect(headers.isEmpty)
    }

    @Test func remoteAudioUsesBearerToken() async throws {
        let episode = makeEpisode()
        episode.audioURL = "https://example.com/audio.m4a"
        let plan = try #require(PodcastPlayerLoadPlan.make(episode: episode))

        let headers = try await PodcastPlayerLoader.resolveAudioHeaders(
            for: plan,
            kgService: StubAuthTokenProvider()
        ) { _ in
            "secret-token"
        }

        #expect(headers == ["Authorization": "Bearer secret-token"])
    }

    private func makeEpisode() -> PodcastEpisode {
        PodcastEpisode(remoteId: "series_ep_1", episodeNumber: 1, title: "Pilot", durationSec: 42)
    }
}

private final class StubAuthTokenProvider: AuthTokenProviding {
    func currentAuthToken() async throws -> String { "token" }
    func authTokenWithoutInvalidation() async -> String? { "token" }
    func handleUnauthorized(modelContainer: ModelContainer?, reason: String) async {}
}
#endif
