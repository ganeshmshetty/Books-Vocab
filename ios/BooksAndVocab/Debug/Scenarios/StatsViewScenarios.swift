#if DEBUG && canImport(Playbook)
import Playbook
import SwiftUI
import SwiftData

/// Catalog scenarios for `StatsPresenter` (學習統計儀表板).
///
/// `StatsPresenter` is `@Query`-backed: it reads synced `VocabularyEntry`
/// (`syncStatus == 1 && actionType != "delete"`) and recent `ReviewRecord`
/// (`reviewedAt > 6-months-ago`). Each scenario seeds a fresh in-memory
/// `ModelContainer` with synthetic synced entries + review records spread across
/// recent days (so streak / heatmap / forecast cards populate) inside a
/// `@MainActor` View body — env-default services (`KGService`, auth, review
/// settings store, toast coordinator) resolve on the main actor before `@Query`
/// reads. The summary `.task` is pure local computation (deterministic). The
/// graph `.task` no-ops to the empty graph card when logged out (avoids
/// WKWebView / network), which is the intended catalog rendering.
enum StatsViewScenarios {
    static func register(in playbook: Playbook) {
        playbook.addScenarios(of: "Stats View") {
            Scenario("Populated", layout: .fill) {
                StatsViewScene(fixture: .populated)
            }
            Scenario("Empty", layout: .fill) {
                StatsViewScene(fixture: .empty)
            }
            Scenario("Large counts", layout: .fill) {
                StatsViewScene(fixture: .largeCounts)
            }
            // 關聯圖 card matrix (#2860). Rendering (paint watchdog) and retry are
            // unit-only: a catalog snapshot cannot hold a thumbnail unpainted.
            Scenario("Graph loading", layout: .fill) {
                StatsViewScene(fixture: .populated, graph: .loading)
            }
            Scenario("Graph error 5xx", layout: .fill) {
                StatsViewScene(fixture: .populated, graph: .failedNoCache(KGError.httpError(statusCode: 500, detail: "catalog")))
            }
            Scenario("Graph error offline", layout: .fill) {
                StatsViewScene(fixture: .populated, graph: .failedNoCache(KGError.offline))
            }
            Scenario("Graph stale 5xx", layout: .fill) {
                StatsViewScene(fixture: .populated, graph: .failedCached(KGError.httpError(statusCode: 500, detail: "catalog")))
            }
        }
    }
}

// MARK: - Fixtures

private enum StatsViewFixture {
    case populated
    case empty
    case largeCounts

    var vocabularyID: UIWorldVocabularyFixtureID {
        switch self {
        case .populated:
            return .statsPopulated
        case .empty:
            return .statsEmpty
        case .largeCounts:
            return .p11ReviewMix
        }
    }

    var expected: StatsViewExpectedShape {
        switch self {
        case .populated:
            return .init(visibleEntries: .atLeast(8), reviewRecords: .atLeast(12))
        case .empty:
            return .init(visibleEntries: .exactly(0), reviewRecords: .exactly(0))
        case .largeCounts:
            return .init(visibleEntries: .exactly(644), reviewRecords: .exactly(0))
        }
    }
}

private struct StatsViewExpectedShape {
    enum Count {
        case exactly(Int)
        case atLeast(Int)

        func validate(_ actual: Int, label: String, fixtureID: UIWorldVocabularyFixtureID) {
            switch self {
            case .exactly(let expected):
                precondition(
                    actual == expected,
                    "UI World vocabulary.\(fixtureID.rawValue) expected exactly \(expected) \(label), got \(actual)"
                )
            case .atLeast(let minimum):
                precondition(
                    actual >= minimum,
                    "UI World vocabulary.\(fixtureID.rawValue) expected at least \(minimum) \(label), got \(actual)"
                )
            }
        }
    }

    let visibleEntries: Count
    let reviewRecords: Count
}

/// Internal (not private) so unit tests can pin the anchor derivation.
enum StatsViewTime {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }()

    /// Deterministic fallback anchor for seeds with no review events (statsEmpty
    /// and p11ReviewMix)
    /// — nothing to derive from, and wall-clock `Date()` would re-introduce
    /// snapshot drift.
    static let emptySeedFallback: Date = fallbackAnchor(calendar: calendar)

    static func fallbackAnchor(calendar: Calendar) -> Date {
        var comps = DateComponents(calendar: calendar, timeZone: calendar.timeZone)
        comps.year = 2026
        comps.month = 6
        comps.day = 1
        comps.hour = 12
        comps.timeZone = calendar.timeZone
        return calendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    /// Frozen "today" so streak / heatmap / forecast snapshots stay stable across
    /// catalog re-runs (the presenter is otherwise `Date()`-relative, which made
    /// this group's reference PNGs drift on every capture). Derived from the
    /// seed's latest review event (noon of that day): a hard-coded date left the
    /// 「複習預測/今日到期」 cards permanently 0 once the seed narrative anchored
    /// on a different day.
    static func anchor(latestReviewedAt: Date?, calendar: Calendar) -> Date {
        guard let latest = latestReviewedAt else { return fallbackAnchor(calendar: calendar) }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: latest) ?? latest
    }

    static func clock(latestReviewedAt: Date?, calendar: Calendar) -> StatsProjectionClock {
        StatsProjectionClock(
            now: anchor(latestReviewedAt: latestReviewedAt, calendar: calendar),
            calendar: calendar
        )
    }
}

/// Injected 關聯圖 card state for catalog rows of the #2860 matrix. Each case
/// maps to what `StatsPresenter` holds after a load (links / latest failure).
private enum StatsGraphState {
    /// Links loaded; the thumbnail paints (Populated / Empty rows).
    case painted
    /// Links not loaded yet and no failure: loading body.
    case loading
    /// Pull failed with no cached links: error panel with reason and retry.
    case failedNoCache(Error)
    /// Pull failed with cached links: cached graph plus stale status row.
    case failedCached(Error)

    var failure: Error? {
        switch self {
        case .painted, .loading:
            return nil
        case .failedNoCache(let error), .failedCached(let error):
            return error
        }
    }

    var keepsCachedLinks: Bool {
        switch self {
        case .painted, .failedCached:
            return true
        case .loading, .failedNoCache:
            return false
        }
    }
}

// MARK: - Scene harness

/// `@MainActor` body so the in-memory container is seeded and env-default
/// services resolve on the main actor before `@Query` reads.
private struct StatsViewScene: View {
    let container: ModelContainer
    let initialSummary: StatsPresentation.Summary
    private let projectionClock: StatsProjectionClock
    /// 關聯圖 card links, derived from the same UI World seed as the entries
    /// (manifest is the single link source; empty when the dataset carries no
    /// links, which legitimately renders the card's empty state). nil while
    /// loading or after a failure with no cache.
    let graphLinks: [KGGraphLink]?
    let injectedGraphFailure: Error?
    private let frozenStore: ReviewSettingsStore

    init(fixture: StatsViewFixture, graph: StatsGraphState = .painted) {
        let seed = FixtureDatasetStore.requireVocabularySeed(for: fixture.vocabularyID)
        do {
            let container = try ModelContainer(
                for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
            // Seed as pending changes only (no broadcast NSManagedObjectContextDidSave).
            // In the async catalog web-view pass this scene renders after the full
            // ~1300-snapshot main pass, whose @Query scenes leave dangling observers
            // once their ModelContainers deallocate; a committing save() here posts a
            // process-wide didSave that those dangling observers trap on
            // (EXC_BREAKPOINT in _SwiftData_SwiftUI). @Query and fetch both see pending
            // inserts, so the stats + 關聯圖 render identically without the save.
            container.mainContext.autosaveEnabled = false
            let entries = try UITestFixtureSeed.insertVocabularySeed(
                seed, into: container.mainContext, save: false
            )
            let visibleEntries = entries.filter(\.shouldAppearInKnowledgeList)
            fixture.expected.visibleEntries.validate(
                visibleEntries.count,
                label: "visible stats entries",
                fixtureID: fixture.vocabularyID
            )

            let records = try container.mainContext.fetch(FetchDescriptor<ReviewRecord>())
            fixture.expected.reviewRecords.validate(
                records.count,
                label: "review records",
                fixtureID: fixture.vocabularyID
            )

            let clock = StatsViewTime.clock(
                latestReviewedAt: records.map(\.reviewedAt).max(),
                calendar: StatsViewTime.calendar
            )
            self.container = container
            let seededLinks = UIWorldGraphLinks.makeGraphLinks(
                from: visibleEntries,
                fixtureID: fixture.vocabularyID
            )
            self.graphLinks = graph.keepsCachedLinks ? seededLinks : nil
            self.injectedGraphFailure = graph.failure
            self.initialSummary = StatsPresentation.project(.init(
                entries: visibleEntries,
                reviewRecords: records,
                forecastDays: 14,
                clock: clock
            ))
            self.frozenStore = Self.makeFrozenStore(now: clock.now)
            self.projectionClock = clock
        } catch {
            preconditionFailure("Failed to materialize UI World vocabulary.\(fixture.vocabularyID.rawValue) for Stats View catalog: \(error)")
        }
    }

    var body: some View {
        AppThemeContainer {
            StatsPresenter(
                filter: NotebookFilter(),
                initialSummary: initialSummary,
                initialGraphLinks: graphLinks,
                shouldLoadGraphData: false,
                injectedGraphFailure: injectedGraphFailure
            )
                .modelContainer(container)
        }
        .environmentObject(AppAppearanceStore.preview)
        .environment(\.statsProjectionClock, projectionClock)
        // The presenter's `.task` recomputes `summary` using
        // `reviewSettingsStore.settings.reviewReferenceDate()` as "now", which is
        // live `Date()` unless progress is paused — that recompute would override
        // the frozen `initialSummary` and re-introduce date drift. Inject a paused
        // store anchored at the seed-derived frozen now so the live recompute is
        // deterministic too.
        .environment(\.reviewSettingsStore, frozenStore)
    }

    /// A paused `ReviewSettingsStore` whose reference date is pinned to the
    /// seed-derived frozen now, making the presenter's `@Query`-driven
    /// summary recompute deterministic across catalog runs.
    private static func makeFrozenStore(now: Date) -> ReviewSettingsStore {
        var settings = ReviewSettings.default
        settings.isProgressPaused = true
        settings.progressPausedAt = now
        return ReviewSettingsStore(previewSettings: settings)
    }
}
#endif
