import XCTest

final class PodcastPlaybackPerfUITests: UITestCase {
    private let sustainedPlaybackSeconds: TimeInterval = 60
    private let minimumElapsedAdvance: TimeInterval = 55

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 180
    }

    @MainActor
    func testPodcastPlaybackProbeSustainsRealAudioPlayback() throws {
        let app = launchIsolatedApp(
            fixtures: [.podcastPlayablePreview, .entitlementsProAccess],
            perfLog: "audio,scroll,underline,layout,render"
        )
        captureStep("launch", app: app)

        let podcast = try step("podcast-tab", app: app) {
            let page = AppPage(app: app).goToPodcasts()
            XCTAssertTrue(app.waitForNavigationToSettle())
            return page
        }

        guard podcast.anySeriesCard.waitUntilExists(timeout: 15) else {
            captureStep("no-series-card", app: app)
            XCTFail("podcast.playablePreview fixture should render a podcast series")
            return
        }
        try step("series-detail", app: app) {
            podcast.tapFirstSeries()
            XCTAssertTrue(app.waitForNavigationToSettle())
        }

        guard podcast.anyEpisodeRow.waitUntilExists(timeout: 10) else {
            captureStep("no-episode-row", app: app)
            XCTFail("podcast.playablePreview fixture should render an episode row")
            return
        }
        try step("episode-tapped", app: app) {
            podcast.tapFirstEpisode()
            XCTAssertTrue(app.waitForNavigationToSettle())
        }

        if podcast.loginSheet.waitUntilExists(timeout: 1) {
            captureStep("unexpected-login-sheet", app: app)
            XCTFail("lab podcast fixture should be authenticated; login sheet means this probe is not testing playback")
            return
        }

        if podcast.playerLoginGate.waitUntilExists(timeout: 1) {
            captureStep("unexpected-player-login-gate", app: app)
            XCTFail("lab podcast fixture should satisfy podcast access; login gate means this probe is not testing playback")
            return
        }

        guard podcast.playPauseButton.waitUntilExists(timeout: 10) else {
            captureStep("player-not-playable", app: app)
            XCTFail("lab podcast fixture should reach a playable player")
            return
        }
        captureStep("player-ready", app: app)
        try step("play-tapped", app: app) {
            podcast.playPauseButton.tap()
        }

        XCTAssertTrue(
            podcast.pauseButton.waitUntilExists(timeout: 3),
            "播放後 control 必須切成 pauseButton，證明 PodcastPlayerViewModel.state == .playing"
        )
        captureStep("play-verified", app: app)

        let initialElapsed = try readElapsedSeconds(from: podcast)
        RunLoop.current.run(until: Date().addingTimeInterval(sustainedPlaybackSeconds))
        let latestElapsed = try readElapsedSeconds(from: podcast)

        captureStep("playback-sustained", app: app)
        attachText(
            """
            fixtureDataset=marketing_demo
            runtimePodcast=playablePreview
            initialElapsed=\(initialElapsed)
            latestElapsed=\(latestElapsed)
            elapsedAdvance=\(latestElapsed - initialElapsed)
            requiredAdvance=\(minimumElapsedAdvance)
            observationWindow=\(sustainedPlaybackSeconds)
            """,
            named: "Podcast Sustained Playback Metrics"
        )
        XCTAssertGreaterThanOrEqual(
            latestElapsed - initialElapsed,
            minimumElapsedAdvance,
            "Podcast 必須真播放一段時間；elapsedTime 沒有足夠前進代表只切到 playing 狀態但音訊可能卡住"
        )
        XCTAssertTrue(
            podcast.pauseButton.exists,
            "長播放窗口後仍應維持 pauseButton，避免播放立即停止或重置"
        )
    }

    private func readElapsedSeconds(
        from podcast: PodcastPage,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) throws -> TimeInterval {
        XCTAssertTrue(
            podcast.elapsedTimeLabel.waitUntilExists(timeout: 3),
            "播放器必須暴露 elapsedTime 供 UITest 驗證真播放進度",
            file: file,
            line: line
        )
        guard let seconds = Self.parseClock(podcast.elapsedTimeLabel.label) else {
            XCTFail("無法解析 elapsedTime：\(podcast.elapsedTimeLabel.label)", file: file, line: line)
            throw NSError(
                domain: "PodcastPlaybackPerfUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "elapsedTime 不可解析"]
            )
        }
        return seconds
    }

    private static func parseClock(_ raw: String) -> TimeInterval? {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap(Int.init)
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 2 {
            return TimeInterval(numbers[0] * 60 + numbers[1])
        }
        return TimeInterval(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
    }
}
