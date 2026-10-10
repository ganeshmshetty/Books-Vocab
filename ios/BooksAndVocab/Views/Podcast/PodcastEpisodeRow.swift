import SwiftUI
import SwiftData

struct PodcastEpisodeRow: View {
    @ObserveInjection private var inject
    let episode: PodcastEpisode
    let progress: PodcastProgress?
    /// Pro-locked for the current tier (guest, or free on a non-preview episode).
    /// Renders a lock accessory instead of the play affordance; the caller wires
    /// the tap to the login sheet / paywall rather than navigation.
    let locked: Bool
    @Environment(\.appSkin) private var skin
    @Environment(\.kgService) private var kgService
    @Environment(\.toastCoordinator) private var toastCoordinator
    #if os(iOS)
    @State private var downloadManager = PodcastDownloadManager.shared
    #endif

    init(episode: PodcastEpisode, progress: PodcastProgress? = nil, locked: Bool = false) {
        self.episode = episode
        self.progress = progress
        self.locked = locked
    }

    private var isCompleted: Bool { progress?.completed == true }
    #if os(iOS)
    private var downloadProgress: Double? { downloadManager.progress[episode.remoteId] }
    private var downloadFailed: Bool { downloadManager.failed[episode.remoteId] != nil }
    private var isDownloaded: Bool {
        guard let path = episode.localAudioPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Required-auth seam for the user-initiated download path.
    /// Required-auth: 不以本地時鐘判斷過期（#2806）；過期由伺服器 401 經 authedResponseData／authenticatedRequest 登出。
    static func downloadAuthToken(kgService: any AuthTokenProviding) async throws -> String {
        try await kgService.currentAuthToken()
    }

    /// Kick off (or retry) the offline download. Fetches a fresh auth token so
    /// the manager keeps zero dependency on KGService. `startDownload` clears any
    /// prior `failed[remoteId]` entry, so this doubles as the retry path.
    private func startDownloadTask() {
        Task {
            do {
                let token = try await Self.downloadAuthToken(kgService: kgService)
                downloadManager.startDownload(episode: episode, authToken: token)
            } catch {
                AppLog.app.error("download auth token failed: \(error.localizedDescription, privacy: .public)")
                toastCoordinator.error(Self.downloadFailureMessage(for: error))
            }
        }
    }

    /// User-facing cause when the download cannot even start (offline / expired login).
    static func downloadFailureMessage(for error: Error) -> String {
        SyncFailurePresentation.reason(for: error)
    }
    #endif
    private var hasProgress: Bool {
        guard let p = progress else { return false }
        return !p.completed && p.lastPlayedTime > 0 && episode.durationSec > 0
    }
    private var progressFraction: Double {
        guard hasProgress, let p = progress else { return 0 }
        return min(1, p.lastPlayedTime / episode.durationSec)
    }

    var body: some View {
        // 對齊單字 WordRow 的列節奏：水平 wordRowHorizontalGap、垂直 wordRowVerticalGap、
        // metadata monoLabel、compactRowVerticalPadding（皆與 WordRow 一致）。標題刻意保留
        // serif sectionTitle —— WordRow 的 rowWord 是 systemMono（適合單字 token），但 episode
        // 標題為散文，套 mono 反而視覺退步，故只對齊版面節奏不對齊標題字體。
        HStack(alignment: .top, spacing: skin.spacing.wordRowHorizontalGap) {
            VStack(alignment: .leading, spacing: skin.spacing.wordRowVerticalGap) {
                Text(episode.title)
                    .font(skin.typography.sectionTitle)
                    .foregroundStyle(episode.audioAvailable ? skin.palette.primaryText : skin.palette.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                metadataLine

                if hasProgress {
                    ProgressCapsule(
                        progress: progressFraction,
                        label: nil,
                        fillColor: skin.palette.accent,
                        trackColor: skin.palette.progressBarBackground,
                        height: 3
                    )
                    .padding(.top, skin.spacing.tinyGap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingAccessory
                .padding(.top, skin.spacing.compactRowAccessoryTopInset)
        }
        .padding(.vertical, skin.spacing.compactRowVerticalPadding)
        .padding(.horizontal, skin.spacing.cardPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        #if os(iOS)
        .contextMenu { downloadMenuItems }
        #endif
        .enableInjection()
    }

    #if os(iOS)
    @ViewBuilder
    private var downloadMenuItems: some View {
        if !episode.audioAvailable {
            EmptyView()
        } else if downloadProgress != nil {
            Button(role: .destructive) {
                downloadManager.cancel(remoteId: episode.remoteId)
            } label: {
                Label(L10n.string("取消下載"), systemImage: "xmark.circle")
            }
        } else if isDownloaded {
            Button(role: .destructive) {
                downloadManager.deleteLocal(episode: episode)
            } label: {
                Label(L10n.string("移除下載"), systemImage: "trash")
            }
        } else if downloadFailed {
            Button {
                startDownloadTask()
            } label: {
                Label(L10n.string("重試下載"), systemImage: "arrow.clockwise")
            }
        } else {
            Button {
                startDownloadTask()
            } label: {
                Label(L10n.string("下載供離線播放"), systemImage: "arrow.down.circle")
            }
        }
    }
    #endif

    private var metadataLine: some View {
        HStack(spacing: skin.spacing.metadataGap) {
            Text("Ep \(episode.episodeNumber)") // i18n-allow: technical prefix
                .font(skin.typography.monoLabel)
                .foregroundStyle(skin.palette.secondaryText)

            Text("·") // i18n-allow: visual separator
                .font(skin.typography.monoLabel)
                .foregroundStyle(skin.palette.quaternaryText)

            Text(formatDate(episode.createdAt))
                .font(skin.typography.monoLabel)
                .foregroundStyle(skin.palette.tertiaryText)

            Text("·") // i18n-allow: visual separator
                .font(skin.typography.monoLabel)
                .foregroundStyle(skin.palette.quaternaryText)

            Text(formatDuration(episode.durationSec))
                .font(skin.typography.monoLabel)
                .foregroundStyle(skin.palette.tertiaryText)

            if episode.subtitleAvailable {
                Image(systemName: "captions.bubble.fill")
                    .font(skin.typography.iconTiny)
                    .foregroundStyle(skin.palette.success)
                    .accessibilityLabel(L10n.string("podcast.episodeRow.subtitleAvailable"))
            }

            #if os(iOS)
            downloadIndicator
            #endif
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var downloadIndicator: some View {
        if let frac = downloadProgress {
            // Active download — compact progress ring.
            ZStack {
                Circle()
                    .stroke(skin.palette.progressBarBackground, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: frac)
                    .stroke(skin.palette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            .animation(AppMotion.indicatorTransition, value: frac)
            .accessibilityLabel(L10n.string("podcast.episodeRow.downloading"))
            .accessibilityValue("\(Int((frac * 100).rounded()))%")
        } else if downloadFailed {
            // 下載失敗 → 可點重試徽章。先前 `failed` dict 全無 view 讀取，失敗
            // 後使用者完全無回饋且無從重試（只能長按 contextMenu）。對齊 BookCard
            // 的 iCloud retryBadge 模式。tap 走 startDownloadTask（startDownload
            // 會清掉 failed[remoteId]，故同一路徑即重試）。
            Button {
                startDownloadTask()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(skin.typography.iconTiny)
                    .foregroundStyle(skin.palette.warning)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("podcast.episodeRow.downloadFailed"))
        } else if isDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .font(skin.typography.iconTiny)
                .foregroundStyle(skin.palette.success)
                .accessibilityLabel(L10n.string("podcast.episodeRow.downloaded"))
        }
    }
    #endif

    @ViewBuilder
    private var trailingAccessory: some View {
        if locked {
            Image(systemName: "lock.fill")
                .font(skin.typography.iconSmall)
                .foregroundStyle(skin.palette.tertiaryText)
                .accessibilityLabel(L10n.string("podcast.locked.episode.a11y"))
        } else if isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .font(skin.typography.iconSmall)
                .foregroundStyle(skin.palette.success)
                .accessibilityLabel(L10n.string("podcast.episodeRow.listened"))
        } else if !episode.audioAvailable {
            Image(systemName: "icloud.slash")
                .font(skin.typography.iconSmall)
                .foregroundStyle(skin.palette.quaternaryText)
                .accessibilityLabel(L10n.string("podcast.episodeRow.unavailable"))
        } else {
            Image(systemName: "play.circle.fill")
                .font(skin.typography.iconSmall)
                .foregroundStyle(skin.palette.accent)
                .accessibilityHidden(true)
        }
    }

    private func formatDuration(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "--:--" }
        let total = Int(sec)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L10n.string("今天") }
        if cal.isDateInYesterday(date) { return L10n.string("昨天") }
        let sameYear = cal.isDate(date, equalTo: Date(), toGranularity: .year)
        // template → ICU 給各 locale 最佳化:
        // sameYear: en="May 22" / ja="5月22日" / zh-Hant="5月22日" / ko="5월 22일"
        // crossYear: en="May 22, 2025" / ja="2025年5月22日" / zh-Hant="2025/5/22"
        let template = sameYear ? "Md" : "yMd"
        return LocaleAwareFormatter.shared.string(from: date, template: template)
    }
}

#if os(iOS)
#Preview("PodcastEpisodeRow") {
    func makeEpisode(_ number: Int, _ title: String, audio: Bool = true, subtitle: Bool = true) -> PodcastEpisode {
        let ep = PodcastEpisode(remoteId: "ep-\(number)", episodeNumber: number, title: title, durationSec: 932)
        ep.audioAvailable = audio
        ep.subtitleAvailable = subtitle
        return ep
    }

    let plain = makeEpisode(1, "The Comfort Crisis")
    let inProgress = makeEpisode(2, "On Deep Work and Attention")
    let completed = makeEpisode(3, "Habits That Compound")
    let unavailable = makeEpisode(4, "Pending Upload", audio: false, subtitle: false)

    return AppThemeContainer {
        VStack(spacing: 0) {
            PodcastEpisodeRow(episode: plain)
            PodcastEpisodeRow(
                episode: inProgress,
                progress: PodcastProgress(episodeRemoteId: "ep-2", lastPlayedTime: 410)
            )
            PodcastEpisodeRow(
                episode: completed,
                progress: PodcastProgress(episodeRemoteId: "ep-3", lastPlayedTime: 932, completed: true)
            )
            PodcastEpisodeRow(episode: unavailable)
        }
        .padding(.vertical)
    }
    .environmentObject(AppAppearanceStore.preview)
}
#endif
