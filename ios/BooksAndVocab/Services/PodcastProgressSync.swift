import Foundation
import SwiftData

// MARK: - API Models

/// One row returned by ``GET /api/podcasts/progress`` or
/// ``GET /api/podcasts/{series}/{ep}/progress``.
struct PodcastRemoteProgressItem: Codable, Equatable {
    let seriesId: String
    let epNum: Int
    let positionSec: Double
    let durationSec: Double
    /// ISO8601 UTC — the backend canonicalises to ``+00:00`` so direct
    /// string comparison is valid as a last-write-wins primary key.
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case seriesId = "series_id"
        case epNum = "ep_num"
        case positionSec = "position_sec"
        case durationSec = "duration_sec"
        case updatedAt = "updated_at"
    }
}

private struct _ProgressListResponse: Codable {
    let items: [PodcastRemoteProgressItem]
}

// MARK: - Throttle state

/// Tracks the last successful push so the player loop can decide whether to
/// send another one. Used by ``PodcastPlayerView`` to gate writes triggered
/// by the high-frequency ``onChange(of: currentTime)`` callback.
///
/// Rules:
/// * First write of the session → always allow.
/// * Subsequent ticks → require either ≥ 10s elapsed OR ≥ 5% position jump
///   relative to duration (so manual scrubs flush immediately).
/// * ``.pause`` and ``.episodeSwitch`` reasons bypass the gates entirely —
///   those are user-visible state transitions and must be durable.
/// * ``duration == 0`` (audio not yet loaded) blocks tick writes; the
///   pause / episodeSwitch path is unaffected.
struct PodcastProgressPushState {
    enum Reason {
        case tick
        case pause
        case episodeSwitch
    }

    private var lastPushedAt: Date?
    private var lastPushedPosition: Double?

    static let minInterval: TimeInterval = 10
    static let minPercentJump: Double = 0.05

    func shouldPush(
        position: Double,
        duration: Double,
        now: Date,
        reason: Reason
    ) -> Bool {
        switch reason {
        case .pause, .episodeSwitch:
            return true
        case .tick:
            break
        }

        if duration <= 0 { return false }

        guard let lastAt = lastPushedAt, let lastPos = lastPushedPosition else {
            return true
        }

        let elapsed = now.timeIntervalSince(lastAt)
        let percentJump = abs(position - lastPos) / duration

        if elapsed >= Self.minInterval || percentJump >= Self.minPercentJump {
            return true
        }
        return false
    }

    /// Commits the throttle baseline after the corresponding request succeeds.
    /// A late completion for an older snapshot cannot move the baseline back.
    mutating func recordSuccessfulPush(position: Double, now: Date) {
        if let lastAt = lastPushedAt {
            let isNewer = now > lastAt
            let winsSameInstantTie = now == lastAt && position >= (lastPushedPosition ?? 0)
            guard isNewer || winsSameInstantTie else { return }
        }
        lastPushedAt = now
        lastPushedPosition = position
    }
}

// MARK: - Service extensions

extension PodcastSyncService {
    /// Mirrors `PodcastSyncService.baseURL` (private to its file): pinned to
    /// the public backend, except under the UI-test override — progress sync
    /// must stay hermetic in an isolated test world like every other request.
    private static var progressBaseURL: String {
        #if DEBUG
        return KGService.uiTestServerURLOverride() ?? AppURLs.domain
        #else
        return AppURLs.domain
        #endif
    }

    /// Decompose ``{seriesId}_ep_{NN}`` back into its components.
    /// Returns ``nil`` when the suffix marker (`_ep_`) is missing or the
    /// trailing segment isn't a positive integer.
    static func parseEpisodeRemoteId(_ remoteId: String) -> (seriesId: String, episodeNumber: Int)? {
        guard let range = remoteId.range(of: "_ep_", options: .backwards) else {
            return nil
        }
        let seriesId = String(remoteId[..<range.lowerBound])
        let epStr = String(remoteId[range.upperBound...])
        guard !seriesId.isEmpty,
              let ep = Int(epStr),
              ep >= 1 else {
            return nil
        }
        return (seriesId, ep)
    }

    /// Push a single episode's progress to the backend (last-write-wins).
    func pushProgress(
        seriesId: String,
        episodeNumber: Int,
        positionSec: Double,
        durationSec: Double,
        updatedAt: Date
    ) async throws {
        guard let url = URL(string: "\(Self.progressBaseURL)/api/podcasts/\(seriesId)/\(episodeNumber)/progress") else {
            throw URLError(.badURL)
        }
        let token = try await kgService.currentAuthToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "position_sec": positionSec,
            "duration_sec": durationSec,
            "updated_at": AppDateFormatters.iso8601.string(from: updatedAt),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await sharedURLSession.data(for: request)
        if let http = response as? HTTPURLResponse {
            // #2806: 真實 401 才登出（與 authedResponseData 同一唯一真相），不以本地時鐘判斷。
            if http.statusCode == 401 {
                await kgService.handleUnauthorized(modelContainer: nil, reason: "http_401")
                throw KGError.unauthorized
            }
            if !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
        }
    }

    /// Pull every progress row for the authenticated user.
    func fetchAllProgress() async throws -> [PodcastRemoteProgressItem] {
        let data = try await Self.authedData(
            from: "\(Self.progressBaseURL)/api/podcasts/progress",
            kgService: kgService
        )
        let resp = try JSONDecoder().decode(_ProgressListResponse.self, from: data)
        return resp.items
    }

    // MARK: - Merge

    /// Apply remote rows onto local SwiftData under last-write-wins.
    ///
    /// For each parseable remote item:
    /// 1. Collapse any local duplicates for that episode (CloudKit drift).
    /// 2. If no local row exists, insert one from the remote payload.
    /// 3. Otherwise, compare ``updatedAt`` instants and keep the newer side.
    @MainActor
    static func mergeRemoteProgress(
        remote: [PodcastRemoteProgressItem],
        context: ModelContext
    ) {
        for item in remote {
            guard !item.seriesId.isEmpty, item.epNum >= 1 else { continue }
            guard let remoteUpdatedAt = AppDateFormatters.parseISO8601(item.updatedAt) else {
                continue
            }
            let episodeRemoteId = episodeRemoteId(seriesId: item.seriesId, episodeNumber: item.epNum)

            let surviving = sanitizeProgressDuplicates(for: episodeRemoteId, context: context)

            if let local = surviving {
                // Last-write-wins by instant. On an exact tie (same wall-clock
                // instant, common when two devices push within the same
                // second) the strict `>` would make BOTH devices reject the
                // other and the position diverges forever. Break the tie the
                // same way `sanitizeProgressDuplicates` does — keep the larger
                // `lastPlayedTime` — so the merge is symmetric and converges.
                let remoteWins: Bool
                if remoteUpdatedAt > local.updatedAt {
                    remoteWins = true
                } else if remoteUpdatedAt == local.updatedAt {
                    remoteWins = item.positionSec > local.lastPlayedTime
                } else {
                    remoteWins = false
                }
                if remoteWins {
                    local.lastPlayedTime = item.positionSec
                    local.updatedAt = remoteUpdatedAt
                    if item.durationSec > 0 {
                        local.completed = item.positionSec >= item.durationSec - 1
                    }
                }
            } else {
                let progress = PodcastProgress(
                    episodeRemoteId: episodeRemoteId,
                    lastPlayedTime: item.positionSec,
                    completed: item.durationSec > 0 && item.positionSec >= item.durationSec - 1
                )
                progress.updatedAt = remoteUpdatedAt
                context.insert(progress)
            }
        }
    }
}

// MARK: - Date formatter
//
// Wire format ISO 8601 helpers live in ``AppDateFormatters``:
// - ``iso8601`` — withInternetDateTime + withFractionalSeconds (encode form).
//   Backend-compatible: the router parses with ``datetime.fromisoformat``
//   (accepts fractional seconds) and re-emits via ``isoformat()``, which
//   preserves the sub-second component verbatim when present.
// - ``parseISO8601`` — tries fractional first, falls back to plain
//   withInternetDateTime. Needed because the backend only emits a fraction
//   when ``datetime.microsecond != 0``, so legacy / whole-second rows arrive
//   without one and ``ISO8601DateFormatter`` is strict about the option.
