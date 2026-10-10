import Foundation
import SwiftData

extension Notification.Name {
    /// Posted by `PodcastSyncService.syncAll` after a successful catalog
    /// reconcile (`.completed`). Views that froze their `@Query` into a
    /// one-shot `@State` snapshot (see `PodcastEpisodeListView`'s freeze-fix)
    /// listen for this to discretely re-read the store — `seriesId` is stable
    /// across a background upsert so `.task(id:)` won't re-fire on its own.
    static let podcastCatalogDidSync = Notification.Name("podcastCatalogDidSync")
}

// MARK: - API Response Models

struct PodcastSeriesSummary: Codable, Sendable {
    let id: String
    let title: String
    let author: String?
    let hostNames: [String]?
    let color: String?
    let coverPattern: String?
    let coverImageURL: String?
    let totalDurationSec: Double?
    let episodeCount: Int?
    /// 伺服器的內容指紋。**一直都在清單裡**，只是這個型別以前沒解它。
    ///
    /// `index.json` 是 `metadata.json` 的機械式投影（去掉 episodes、補上
    /// episodeCount，見 `ops/podcast_upload.sh`），所以清單天生帶著和 detail
    /// 一樣的 `updatedAt`。2026-08-06 對生產驗過：四個 series 全部有值。
    /// 這一個欄位就是「不必抓 detail 也知道它沒變」的全部依據。
    let updatedAt: String?
}

struct PodcastSeriesDetail: Codable, Sendable {
    let id: String
    let title: String
    let author: String?
    let hostNames: [String]?
    let color: String?
    let coverPattern: String?
    let coverImageURL: String?
    let totalDurationSec: Double?
    let episodes: [PodcastEpisodeDetail]
    let createdAt: String?
    let updatedAt: String?
}

struct PodcastEpisodeDetail: Codable, Sendable {
    let episodeNumber: Int
    let title: String
    let durationSec: Double
    let audioAvailable: Bool
    let subtitleAvailable: Bool
    /// SRT content inlined by `ops/podcast_upload.sh`. When present the
    /// player skips the per-episode subtitle fetch entirely. Optional —
    /// older series uploaded before the embed change won't carry it.
    let subtitleContent: String?
    /// Free-tier preview fields (ep 1 only). Written by `ops/podcast_upload.sh`
    /// / `ops/podcast_preview_backfill.py`; absent on pre-preview series → false/0.
    let previewAvailable: Bool
    let previewDurationSec: Double

    private enum CodingKeys: String, CodingKey {
        case episodeNumber, title, durationSec, audioAvailable, subtitleAvailable, subtitleContent
        case previewAvailable, previewDurationSec
    }

    init(
        episodeNumber: Int,
        title: String,
        durationSec: Double,
        audioAvailable: Bool,
        subtitleAvailable: Bool,
        subtitleContent: String?,
        previewAvailable: Bool = false,
        previewDurationSec: Double = 0
    ) {
        self.episodeNumber = episodeNumber
        self.title = title
        self.durationSec = durationSec
        self.audioAvailable = audioAvailable
        self.subtitleAvailable = subtitleAvailable
        self.subtitleContent = subtitleContent
        self.previewAvailable = previewAvailable
        self.previewDurationSec = previewDurationSec
    }

    /// Custom decode for resilience against hand-assembled S3 metadata.json
    /// (`ops/podcast_upload.sh` stitches it by hand — no Pydantic guarantee).
    /// One episode dropping a non-identity field used to throw and make the
    /// *entire series* invisible (whole-detail decode is all-or-nothing, and
    /// `syncAll` swallows the per-series failure). Identity fields
    /// (`episodeNumber` / `title`) stay required — a missing one makes the
    /// episode meaningless. The rest graceful-degrade to safe defaults:
    /// - `durationSec` → 0 (renders 0:00; the only divisor site,
    ///   `PodcastEpisodeRow.progressFraction`, is guarded by `durationSec > 0`,
    ///   so 0 cannot divide-by-zero).
    /// - `audioAvailable` → false (shows non-playable, far better than the
    ///   whole series vanishing).
    /// - `subtitleAvailable` → false (no subtitle).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeNumber = try c.decode(Int.self, forKey: .episodeNumber)
        title = try c.decode(String.self, forKey: .title)
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0
        audioAvailable = try c.decodeIfPresent(Bool.self, forKey: .audioAvailable) ?? false
        subtitleAvailable = try c.decodeIfPresent(Bool.self, forKey: .subtitleAvailable) ?? false
        subtitleContent = try c.decodeIfPresent(String.self, forKey: .subtitleContent)
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable) ?? false
        previewDurationSec = try c.decodeIfPresent(Double.self, forKey: .previewDurationSec) ?? 0
    }
}

// MARK: - Sync Service

final class PodcastSyncService {
    /// Podcast assets are only hosted on the public backend, so this stays
    /// pinned to `AppURLs.domain` even in debug-local server mode. The single
    /// exception is the UI-test override: an isolated test world must never
    /// sync against the real catalog (reconcile would tombstone seeded series).
    private static var baseURL: String {
        #if DEBUG
        return KGService.uiTestServerURLOverride() ?? AppURLs.domain
        #else
        return AppURLs.domain
        #endif
    }

    // 同檔案以外的 extension（如 PodcastProgressSync.swift）需要 access；
    // 改 internal 不對外暴露，僅在 module 內可見。
    let kgService: any KGServing
    let catalogTransport: PodcastCatalogTransport

    init(
        kgService: any KGServing,
        catalogTransport: PodcastCatalogTransport = .live()
    ) {
        self.kgService = kgService
        self.catalogTransport = catalogTransport
    }

    static func episodeRemoteId(seriesId: String, episodeNumber: Int) -> String {
        "\(seriesId)_ep_\(String(format: "%02d", episodeNumber))"
    }

    static func audioURL(seriesId: String, episodeNumber: Int) -> String {
        // Authenticated endpoint with HTTP Range support. AVPlayer attaches the
        // Bearer token via `AVURLAssetHTTPHeaderFieldsKey` (see `PodcastPlayerView`).
        "\(baseURL)/api/podcasts/\(seriesId)/\(episodeNumber)/audio"
    }

    static func subtitleURL(seriesId: String, episodeNumber: Int) -> String {
        "\(baseURL)/api/podcasts/\(seriesId)/\(episodeNumber)/subtitle"
    }

    /// Shared helper so `PodcastPlayerView` 的 subtitle / audio metadata fetch 也能重用。
    ///
    /// Non-2xx throws `URLError(.badServerResponse)`: an error body (503 / 404
    /// JSON) must never reach callers as if it were the resource — a subtitle
    /// error body parsed to zero cues and surfaced as "no subtitles" with no
    /// retry (#2106).
    static func authedData(
        from urlString: String,
        kgService: any AuthTokenProviding,
        session: URLSession = sharedURLSession
    ) async throws -> Data {
        let (data, response) = try await authedResponseData(
            from: urlString, kgService: kgService, session: session
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func authedResponseData(
        from urlString: String,
        kgService: any AuthTokenProviding,
        session: URLSession = sharedURLSession
    ) async throws -> (Data, URLResponse) {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let token = try await kgService.currentAuthToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        // #2806: 與 KGService.authenticatedRequest 相同的唯一真相——伺服器真實 401 才登出。
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            await kgService.handleUnauthorized(modelContainer: nil, reason: "http_401")
            throw KGError.unauthorized
        }
        return (data, response)
    }

    /// Browse fetch that tolerates an anonymous (guest) caller. The backend
    /// podcast *browse* endpoints (`/api/podcasts`, `/{sid}`, `/{sid}/cover`)
    /// admit guests, so we attach the Bearer token only when one is present —
    /// a logged-out user can still load the catalog/showcase. Playback
    /// endpoints stay on `authedData` (they require a real user). An expired
    /// token is treated as absent without invalidating the session.
    static func optionallyAuthedData(
        from urlString: String,
        kgService: any KGServing,
        session: URLSession = sharedURLSession
    ) async throws -> Data {
        let (data, _) = try await optionallyAuthedResponseData(
            from: urlString, kgService: kgService, session: session
        )
        return data
    }

    static func optionallyAuthedResponseData(
        from urlString: String,
        kgService: any KGServing,
        session: URLSession = sharedURLSession
    ) async throws -> (Data, URLResponse) {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = await kgService.authTokenWithoutInvalidation() {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await session.data(for: request)
    }

    // Compatibility wrappers; cover lifecycle is owned by PodcastCoverCaching.
    static func coversRoot() -> URL { PodcastCoverCaching.coversRoot() }
    static func cachedCoverURL(seriesId: String) -> URL {
        PodcastCoverCaching.cachedCoverURL(seriesId: seriesId)
    }
    static func cachedCoverURL(seriesId: String, coverImageURL: String?) -> URL {
        PodcastCoverCaching.cachedCoverURL(seriesId: seriesId, coverImageURL: coverImageURL)
    }
    static func coverCacheToken(from coverImageURL: String?) -> String? {
        PodcastCoverCaching.coverCacheToken(from: coverImageURL)
    }
    static func removeCachedCover(seriesId: String, path: String? = nil) {
        PodcastCoverCaching.removeCachedCover(seriesId: seriesId, path: path)
    }
    static func isValidCoverResponse(data: Data, response: URLResponse) -> Bool {
        PodcastCoverCaching.isValidResponse(data: data, response: response)
    }
    static func cacheCovers(
        seriesIds: [String], maxConcurrent: Int = 3,
        operation: @escaping (String) async -> Void
    ) async { await PodcastCoverCaching.cacheCovers(seriesIds: seriesIds, maxConcurrent: maxConcurrent, operation: operation) }
    @MainActor
    static func cacheCoverIfNeeded(
        seriesId: String, context: ModelContext, kgService: any KGServing
    ) async {
        await PodcastCoverCaching.cacheCoverIfNeeded(
            seriesId: seriesId, context: context, kgService: kgService,
            baseURL: baseURL,
            fetch: { url in try await optionallyAuthedResponseData(from: url, kgService: kgService) }
        )
    }

    func fetchSeriesList() async throws -> [PodcastSeriesSummary] {
        // Browse is open to guests — attach a token only if signed in.
        let token = await kgService.authTokenWithoutInvalidation()
        let data = try await catalogTransport.data(
            from: "\(Self.baseURL)\(catalogTransport.basePath)", bearerToken: token
        )
        return try catalogTransport.decode([PodcastSeriesSummary].self, from: data)
    }

    func fetchSeriesDetail(seriesId: String) async throws -> PodcastSeriesDetail {
        let token = await kgService.authTokenWithoutInvalidation()
        let data = try await catalogTransport.data(
            from: "\(Self.baseURL)\(catalogTransport.basePath)/\(seriesId)",
            bearerToken: token
        )
        return try catalogTransport.decode(PodcastSeriesDetail.self, from: data)
    }

    /// Outcome of a `syncAll` pass. Only the list fetch is fatal (a complete
    /// no-op refresh the user explicitly triggered); detail / progress / save
    /// failures are partial or auxiliary and stay swallowed as before.
    enum SyncOutcome: Equatable {
        /// List fetch returned (catalog reconciled); refresh did something.
        case completed
        /// Cancelled mid-flight (view torn down / task superseded) — not an error.
        case cancelled
        /// Series-list fetch failed → nothing refreshed. Surface to user when
        /// the sync was an explicit pull-to-refresh.
        case listFetchFailed
    }

    /// Full sync: fetch all series, upsert into SwiftData, then reconcile orphans.
    /// Detail fetch failures for individual series are swallowed — we still
    /// upsert what succeeded and feed only the succeeded set to reconcile so
    /// transient 404/timeout cannot trigger episode mass-deletion.
    ///
    /// Returns a `SyncOutcome`; callers that ran a silent/background sync ignore
    /// it (`@discardableResult`), while pull-to-refresh checks it to surface a
    /// toast on `.listFetchFailed`.
    @MainActor
    @discardableResult
    func syncAll(context: ModelContext) async -> SyncOutcome {
        let summaries: [PodcastSeriesSummary]
        do {
            summaries = try await fetchSeriesList()
        } catch is CancellationError {
            // Task superseded / view torn down mid-fetch — not a user-facing error.
            AppLog.kg.warning("[PodcastSync] list fetch cancelled")
            return .cancelled
        } catch {
            // List fetch failure → skip reconcile (空 list 會誤刪所有 series).
            AppLog.kg.warning("[PodcastSync] list fetch failed: \(error.localizedDescription)")
            AppCrashReporting.record(error, context: "podcast.sync.list")
            return .listFetchFailed
        }
        // 只抓「內容指紋變了」的 series，而且併發抓。
        //
        // 舊版對每個 series 各發一次請求、序列等待：2026-08-06 生產量測 7.55s 的
        // 整輪同步裡有 6.08s 在這個迴圈，而四個 series 的資料總量只有約 7 KB。
        // 貴的是往返次數，不是位元組——每多一個 series，每次同步就多約 1.5 秒。
        //
        // **刻意不走「把 detail 內嵌進 list」那條路。** `episodes[].subtitleContent`
        // 是整份 inline SRT（實測 165–212 KB／集，8 集的 metadata.json ≈ 1.4 MB），
        // 而 `app_middleware.py` 沒掛 GZipMiddleware。內嵌會把 7 KB 的回應變成數 MB，
        // 用頻寬換往返，在行動網路上是虧的。
        //
        // 穩態成本因此是 **1 趟**（只有清單），不是 1+N。
        let localIndex = Self.localSeriesIndex(context: context)
        let stale = summaries.filter {
            Self.needsDetailFetch(summary: $0, local: localIndex[$0.id])
        }
        // 無條件印。舊版包在 `if stale.count < summaries.count` 裡＝「只有健康時才
        // 說話」：退回「全部都得抓」那一輪反而零輸出，方向正好是反的。
        AppLog.kg.info("[PodcastSync] detail fetch total=\(summaries.count) stale=\(stale.count) skipped=\(summaries.count - stale.count)")
        let fetched = await Self.fetchDetailsConcurrently(
            seriesIds: stale.map(\.id)
        ) { [kgService, catalogTransport] seriesId in
            do {
                return try await PodcastSyncService(
                    kgService: kgService, catalogTransport: catalogTransport
                ).fetchSeriesDetail(seriesId: seriesId)
            } catch {
                AppLog.kg.warning("[PodcastSync] detail fetch failed for \(seriesId): \(error.localizedDescription)")
                if !(error is CancellationError) {
                    AppCrashReporting.record(error, context: "podcast.sync.detail")
                }
                return nil
            }
        }
        // upsert 留在 MainActor 上依序做（SwiftData 契約），只有網路那段併發。
        var details: [String: PodcastSeriesDetail] = [:]
        for summary in summaries {
            guard let detail = fetched[summary.id] else { continue }
            details[summary.id] = detail
            Self.upsertSeries(detail: detail, context: context)
        }
        // 封面改由**清單**驅動而非只看這輪抓到的 detail：跳過的 series 也該有機會
        // 補上它上次沒下載成功的封面。已快取者 `cacheCoverIfNeeded` 直接早退，
        // 不產生任何網路請求。
        let coverSeriesIds = summaries
            .filter { !($0.coverImageURL ?? "").isEmpty }
            .map(\.id)
        await Self.cacheCovers(seriesIds: coverSeriesIds) { seriesId in
            await Self.cacheCoverIfNeeded(seriesId: seriesId, context: context, kgService: self.kgService)
        }
        Self.reconcileLocalState(
            serverSummaries: summaries,
            fetchedDetails: details,
            context: context
        )
        // Pull authoritative cross-device progress and merge under LWW.
        // Failure here must NOT abort the series sync — progress is auxiliary,
        // missing it falls back to local SwiftData like before this endpoint
        // existed.
        do {
            let remote = try await fetchAllProgress()
            Self.mergeRemoteProgress(remote: remote, context: context)
        } catch {
            AppLog.kg.warning("[PodcastSync] progress fetch failed: \(error.localizedDescription)")
        }
        do {
            try context.save()
        } catch {
            AppLog.kg.warning("[PodcastSync] context save failed: \(error.localizedDescription)")
            AppCrashReporting.record(error, context: "podcast.sync.save")
        }
        // Notify frozen-snapshot views (e.g. PodcastEpisodeListView) that the
        // store changed so they can discretely re-read. seriesId is stable
        // across a background upsert, so their `.task(id:)` won't re-fire.
        NotificationCenter.default.post(name: .podcastCatalogDidSync, object: nil)
        return .completed
    }

    // MARK: - 降趟：只抓變更過的 series

    @MainActor
    static func localSeriesIndex(context: ModelContext) -> [String: PodcastSeries] {
        let all = (try? context.fetch(FetchDescriptor<PodcastSeries>())) ?? []
        return Dictionary(all.map { ($0.remoteId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 內容指紋。**不是只有 `updatedAt`。**
    ///
    /// 發布工具會在不 bump `updatedAt` 的前提下改動內容：
    /// `ops/podcast_cover_publish.py:109` 換掉 `coverImageURL` 並重建 `index.json`，
    /// 但明文寫著「updatedAt is deliberately NOT bumped」。只比 `updatedAt` 的話，
    /// 那個新封面永遠不會落到已安裝的裝置上——而 `cacheCoverIfNeeded` 讀的是**本機**
    /// 那一列的 `coverImageURL`，所以連「封面清單改由 summary 驅動」都救不了它。
    ///
    /// 因此指紋涵蓋 `index.json` 會投影、而 `upsertSeries` 會寫下的每個欄位。多比
    /// 幾個字串的成本是零，漏比一個欄位的成本是一個永遠修不好的畫面。
    /// 指紋涵蓋的欄位 = **`upsertSeries` 會寫進 `PodcastSeries` 的每一個伺服器欄位**。
    /// 那個對應是刻意的：任何在指紋外的欄位，只要發布工具改了它而不 bump
    /// `updatedAt`，就會永久不同步。`hostNames` / `color` / `coverPattern` 今天
    /// 沒有工具會那樣改，但把它們留在外面就是在賭下一支工具不會。
    nonisolated static func fingerprint(
        updatedAt: String?,
        coverImageURL: String?,
        title: String,
        totalDurationSec: Double?,
        episodeCount: Int?,
        hostNames: [String]?,
        color: String?,
        coverPattern: String?
    ) -> String {
        // U+001F unit separator：不會出現在任何一個欄位裡，所以不同的欄位組合
        // 不可能拼出同一個字串。`String(Double)` 走 `Double.description`，恆為
        // `.` 小數點、與 locale 無關——用 `"\(value)"` 進格式化路徑才會有事。
        [
            updatedAt ?? "",
            coverImageURL ?? "",
            title,
            totalDurationSec.map { String($0) } ?? "",
            episodeCount.map(String.init) ?? "",
            (hostNames ?? []).joined(separator: "\u{1E}"),
            color ?? "",
            coverPattern ?? ""
        ].joined(separator: "\u{1F}")
    }

    nonisolated static func fingerprint(of summary: PodcastSeriesSummary) -> String {
        fingerprint(
            updatedAt: summary.updatedAt, coverImageURL: summary.coverImageURL,
            title: summary.title, totalDurationSec: summary.totalDurationSec,
            episodeCount: summary.episodeCount, hostNames: summary.hostNames,
            color: summary.color, coverPattern: summary.coverPattern
        )
    }

    nonisolated static func fingerprint(of detail: PodcastSeriesDetail) -> String {
        fingerprint(
            updatedAt: detail.updatedAt, coverImageURL: detail.coverImageURL,
            title: detail.title, totalDurationSec: detail.totalDurationSec,
            episodeCount: detail.episodes.count, hostNames: detail.hostNames,
            color: detail.color, coverPattern: detail.coverPattern
        )
    }

    /// 這個 series 需不需要重抓 detail。
    ///
    /// 每一條 `true` 都是「省下這一趟會出錯」的具體情況，不是保守而已：
    /// - **沒見過** → 本機根本沒有 episodes。
    /// - **被 tombstone 過** → 復活時要把 episodes 拿回來。
    /// - **伺服器沒給 `updatedAt`** → 指紋失去它最主要的成分，不省。
    /// - **指紋不同** → 內容真的變了（含只換封面那種不 bump 時戳的變更）。
    /// - **episode 數對不上** → 本機是半套。這條是完整性檢查而不是快取檢查：
    ///   指紋相同但本機只有 3 集而伺服器說 8 集時，靠指紋就會永遠卡在半套狀態。
    ///
    /// **已知盲點（需要工具側配合，不是這裡能解的）**：若發布工具改了 episode
    /// *內部*的欄位（例如 `previewAvailable`）卻既不 bump `updatedAt` 也不重建
    /// `index.json`，清單上不會有任何差異，客戶端無從察覺。
    /// `ops/podcast_preview_backfill.py` 本來就是這樣，已在同一批改成會 bump。
    @MainActor
    static func needsDetailFetch(summary: PodcastSeriesSummary, local: PodcastSeries?) -> Bool {
        guard let local else { return true }
        if local.isSoftDeleted { return true }
        guard let stamp = summary.updatedAt, !stamp.isEmpty else { return true }
        guard local.remoteFingerprint == fingerprint(of: summary) else { return true }
        if let expected = summary.episodeCount, local.episodes.count != expected { return true }
        return false
    }

    /// 併發抓 detail，滑動視窗上限與 `cacheCovers` 同一套形狀（同檔 :243）——
    /// 不重造，也不無上限併發（目錄長大時會變成對後端的 stampede）。
    static func fetchDetailsConcurrently(
        seriesIds: [String],
        maxConcurrent: Int = 3,
        fetch: @escaping @Sendable (String) async -> PodcastSeriesDetail?
    ) async -> [String: PodcastSeriesDetail] {
        guard !seriesIds.isEmpty else { return [:] }
        let limit = max(1, min(maxConcurrent, seriesIds.count))
        var results: [String: PodcastSeriesDetail] = [:]
        await withTaskGroup(of: (String, PodcastSeriesDetail?).self) { group in
            var iterator = seriesIds.makeIterator()
            for _ in 0..<limit {
                if let seriesId = iterator.next() {
                    group.addTask { (seriesId, await fetch(seriesId)) }
                }
            }
            while let (seriesId, detail) = await group.next() {
                if let detail { results[seriesId] = detail }
                if let next = iterator.next() {
                    group.addTask { (next, await fetch(next)) }
                }
            }
        }
        return results
    }

    @MainActor
    static func upsertSeries(
        detail: PodcastSeriesDetail,
        context: ModelContext,
        fetch: PodcastLocalFetch = .live
    ) {
        let seriesId = detail.id
        let descriptor = FetchDescriptor<PodcastSeries>(
            predicate: #Predicate { $0.remoteId == seriesId }
        )
        // A failed lookup is not "absent": inserting here would duplicate the
        // series/episodes already on disk. Bail before any mutation (the
        // fingerprint is not written, so the next sync retries) (#2795).
        let epDescriptor = FetchDescriptor<PodcastEpisode>(
            predicate: #Predicate { $0.series?.remoteId == seriesId }
        )
        guard let existing = try? fetch.fetch(descriptor, in: context),
              let localEpisodes = try? fetch.fetch(epDescriptor, in: context) else { return }
        let series: PodcastSeries

        if let found = existing.first {
            series = found
        } else {
            series = PodcastSeries(
                remoteId: detail.id,
                title: detail.title,
                hostNames: detail.hostNames ?? []
            )
            context.insert(series)
        }

        series.title = detail.title
        series.hostNames = detail.hostNames ?? []
        series.color = detail.color
        series.coverPattern = detail.coverPattern
        series.coverImageURL = detail.coverImageURL
        // Server retracted the cover → drop the orphaned local cache so the card
        // degrades back to the procedural cover instead of rendering a stale photo
        // forever (cacheCoverIfNeeded early-returns on nil remote, never cleans up).
        if (detail.coverImageURL ?? "").isEmpty, series.coverImagePath != nil {
            Self.removeCachedCover(seriesId: seriesId, path: series.coverImagePath)
            series.coverImagePath = nil
        }
        series.totalDurationSec = detail.totalDurationSec ?? 0
        series.episodeCount = detail.episodes.count
        series.updatedAt = Date()
        // 內容指紋。這整支是同步的 `@MainActor`，中間沒有 suspension point，
        // 所以「指紋落地但 episodes 沒落地」今天不可能發生。**但如果之後有人把
        // episode upsert 拆成 async，這行就必須移到最後**——否則會永久跳過重抓。
        // `needsDetailFetch` 的 episode 數檢查是那時的第二道防線。
        series.remoteFingerprint = Self.fingerprint(of: detail)
        // Resurrect: if server brings a previously-tombstoned series back, clear flag.
        if series.isSoftDeleted { series.isSoftDeleted = false }

        // Single fetch + in-memory index instead of one fetch per episode.
        // Mirrors reconcileLocalState's approach — the old per-episode fetch was
        // O(N) @MainActor SwiftData calls, painful at 1000+ episodes.
        let existingByRemoteId = Dictionary(
            localEpisodes.map { ($0.remoteId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for ep in detail.episodes {
            let epRemoteId = Self.episodeRemoteId(seriesId: detail.id, episodeNumber: ep.episodeNumber)
            let episode: PodcastEpisode

            if let found = existingByRemoteId[epRemoteId] {
                episode = found
            } else {
                episode = PodcastEpisode(
                    remoteId: epRemoteId,
                    episodeNumber: ep.episodeNumber,
                    title: ep.title,
                    durationSec: ep.durationSec
                )
                context.insert(episode)
            }

            episode.episodeNumber = ep.episodeNumber
            episode.title = ep.title
            episode.durationSec = ep.durationSec
            episode.audioAvailable = ep.audioAvailable
            episode.subtitleAvailable = ep.subtitleAvailable
            episode.inlineSubtitle = ep.subtitleContent
            episode.previewAvailable = ep.previewAvailable
            episode.previewDurationSec = ep.previewDurationSec
            episode.audioURL = Self.audioURL(seriesId: detail.id, episodeNumber: ep.episodeNumber)
            episode.subtitleURL = Self.subtitleURL(seriesId: detail.id, episodeNumber: ep.episodeNumber)
            episode.series = series
        }
    }

    // MARK: - Reconcile / Sanitize

    /// The extracted components own sanitize and reconcile policy. These
    /// wrappers preserve source compatibility for existing call sites.
    @MainActor
    @discardableResult
    static func sanitizeProgressDuplicates(
        for episodeRemoteId: String,
        context: ModelContext
    ) -> PodcastProgress? {
        PodcastCatalogReconciler.sanitizeProgressDuplicates(
            for: episodeRemoteId, context: context
        )
    }

    @MainActor
    static func reconcileLocalState(
        serverSummaries: [PodcastSeriesSummary],
        fetchedDetails: [String: PodcastSeriesDetail],
        context: ModelContext,
        fetch: PodcastLocalFetch = .live
    ) {
        PodcastCatalogReconciler.reconcile(
            serverSummaries: serverSummaries,
            fetchedDetails: fetchedDetails,
            context: context,
            fetch: fetch
        )
    }
}

/// Local SwiftData fetch seam. A failed fetch must surface as an error so
/// callers skip destructive/insert paths instead of reading it as "empty" (#2795).
struct PodcastLocalFetch {
    var shouldFail: (Any.Type) -> Bool = { _ in false }

    static let live = PodcastLocalFetch()

    @MainActor
    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, in context: ModelContext) throws -> [T] {
        if shouldFail(T.self) { throw CocoaError(.fileReadUnknown) }
        return try context.fetch(descriptor)
    }
}
