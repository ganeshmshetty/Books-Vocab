import Foundation

/// The complete query for the vocabulary library. Review state, search, and
/// ordering are independent dimensions.
struct VocabularyLibraryQuery: Equatable {
    var reviewStates: Set<VocabularyReviewState>
    var searchText: String
    var sort: KGVocabSortOption

    init(
        reviewStates: Set<VocabularyReviewState> = [],
        searchText: String = "",
        sort: KGVocabSortOption = .default
    ) {
        self.reviewStates = reviewStates
        self.searchText = searchText
        self.sort = sort
    }

    var normalized: Self {
        var value = self
        value.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    func withSearchText(_ text: String) -> Self {
        var value = self
        value.searchText = text
        return value
    }

    mutating func toggleReviewState(_ state: VocabularyReviewState) {
        if reviewStates.contains(state) {
            reviewStates.remove(state)
        } else {
            reviewStates.insert(state)
        }
    }

    mutating func setSort(_ option: KGVocabSortOption) {
        sort = option
    }

    mutating func setReviewState(_ state: VocabularyReviewState?) {
        reviewStates = state.map { [$0] } ?? []
    }
}

struct VocabularyReviewQueue: Equatable {
    let due: [VocabularyEntry]
    let unlearned: [VocabularyEntry]

    var isEmpty: Bool { due.isEmpty && unlearned.isEmpty }
    var all: [VocabularyEntry] { due + unlearned }
}

struct VocabularyFacetCounts: Equatable {
    let review: [VocabularyReviewState: Int]

    func reviewCount(for state: VocabularyReviewState) -> Int {
        review[state, default: 0]
    }
}

struct VocabularyEmptyStateContext: Equatable {
    let hasNoEntries: Bool
    let hasVisibleEntries: Bool
    let searchText: String
    let reviewStates: Set<VocabularyReviewState>
}

struct VocabularyLibraryProjection {
    let effectiveQuery: VocabularyLibraryQuery
    let visibleEntries: [VocabularyEntry]
    let facetCounts: VocabularyFacetCounts
    let reviewQueue: VocabularyReviewQueue
    let emptyStateContext: VocabularyEmptyStateContext

    func reviewCount(for state: VocabularyReviewState) -> Int {
        facetCounts.reviewCount(for: state)
    }

}

enum VocabularyEntryPresentation {
    static func pendingEntries(in entries: [VocabularyEntry]) -> [VocabularyEntry] {
        entries.filter(\.shouldUploadOnNextSync)
    }

    /// Produces one query contract with two explicit layers:
    /// scope-wide facets/CTA (stable while searching) and visible rows (search /
    /// review selection applied last). Naming the layers here prevents a future
    /// caller from treating a scope-wide facet as if it were a visible-row count.
    static func project(
        _ entries: [VocabularyEntry],
        query: VocabularyLibraryQuery,
        now: Date
    ) -> VocabularyLibraryProjection {
        let effectiveQuery = query.normalized
        let searchMatches = filterBySearch(entries, searchText: effectiveQuery.searchText)
        let classified = classifyKnowledgeEntries(in: entries, now: now)
        let selectedEntries: [VocabularyEntry]
        if effectiveQuery.reviewStates.isEmpty {
            selectedEntries = searchMatches
        } else {
            let selectedIDs = Set(classified.mergedBucket(for: effectiveQuery.reviewStates).map(\.id))
            selectedEntries = searchMatches.filter { selectedIDs.contains($0.id) }
        }
        let visibleEntries = sortAndFilter(
            selectedEntries,
            searchText: "",
            sortOption: effectiveQuery.sort,
            now: now
        )

        let reviewCounts = Dictionary(uniqueKeysWithValues: VocabularyReviewState.allCases.map { state in
            (state, classified.count(for: state))
        })
        let reviewVisible = uniqueByServerCard(entries.filter(\.shouldAppearInReview))
        let reviewQueue = VocabularyReviewQueue(
            due: reviewVisible.filter { $0.reviewState(at: now) == .due },
            unlearned: reviewVisible.filter { $0.reviewState(at: now) == .unlearned }
        )

        return VocabularyLibraryProjection(
            effectiveQuery: effectiveQuery,
            visibleEntries: visibleEntries,
            facetCounts: VocabularyFacetCounts(review: reviewCounts),
            reviewQueue: reviewQueue,
            emptyStateContext: VocabularyEmptyStateContext(
                hasNoEntries: entries.isEmpty,
                hasVisibleEntries: !visibleEntries.isEmpty,
                searchText: effectiveQuery.searchText,
                reviewStates: effectiveQuery.reviewStates
            )
        )
    }

    /// 同一張 server 卡至多保留一列（#3059 (1)）：sync 競態可能留下共享 `kgCardId` 的重複列，
    /// 複習佇列不得重複出題。無 `kgCardId`（server 尚未確認）的列彼此獨立，全數保留。
    static func uniqueByServerCard(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var seenCardIds = Set<String>()
        return entries.filter { entry in
            guard entry.hasServerCard, let cardId = entry.kgCardId else { return true }
            return seenCardIds.insert(cardId).inserted
        }
    }

    /// 多選模式下實際可被選取的 row id。
    ///
    static func selectableIDs(in entries: [VocabularyEntry]) -> [UUID] {
        entries.map(\.id)
    }

    /// Single-pass partition of knowledge entries into review-state buckets.
    /// Returns counts and the filtered+sorted list for the selected state.
    struct ClassifiedResult {
        var dueBucket: [VocabularyEntry]
        var unlearnedBucket: [VocabularyEntry]
        var reviewedBucket: [VocabularyEntry]

        var dueCount: Int { dueBucket.count }
        var unlearnedCount: Int { unlearnedBucket.count }
        var reviewedCount: Int { reviewedBucket.count }

        func count(for state: VocabularyReviewState) -> Int {
            switch state {
            case .due: return dueCount
            case .unlearned: return unlearnedCount
            case .reviewed: return reviewedCount
            }
        }

        func bucket(for state: VocabularyReviewState) -> [VocabularyEntry] {
            switch state {
            case .due: return dueBucket
            case .unlearned: return unlearnedBucket
            case .reviewed: return reviewedBucket
            }
        }

        func mergedBucket(for states: Set<VocabularyReviewState>) -> [VocabularyEntry] {
            if states.isEmpty {
                return dueBucket + unlearnedBucket + reviewedBucket
            }
            var result: [VocabularyEntry] = []
            for state in VocabularyReviewState.allCases where states.contains(state) {
                result.append(contentsOf: bucket(for: state))
            }
            return result
        }
    }

    static func classifyKnowledgeEntries(
        in entries: [VocabularyEntry],
        now: Date
    ) -> ClassifiedResult {
        var due: [VocabularyEntry] = []
        var unlearned: [VocabularyEntry] = []
        var reviewed: [VocabularyEntry] = []

        for entry in entries {
            guard entry.shouldAppearInReview else { continue }
            switch entry.reviewState(at: now) {
            case .due: due.append(entry)
            case .unlearned: unlearned.append(entry)
            case .reviewed: reviewed.append(entry)
            }
        }

        return ClassifiedResult(
            dueBucket: due,
            unlearnedBucket: unlearned,
            reviewedBucket: reviewed
        )
    }

    static func sortAndFilter(
        _ entries: [VocabularyEntry],
        searchText: String,
        sortOption: KGVocabSortOption = .default,
        now: Date
    ) -> [VocabularyEntry] {
        // Filter first to reduce sort input size
        let base = searchText.isEmpty ? entries : entries.filter {
            $0.word.localizedCaseInsensitiveContains(searchText) ||
            $0.translation.localizedCaseInsensitiveContains(searchText)
        }

        switch sortOption {
        case .default:
            return base.sorted { compareKnowledgeEntries($0, $1, now: now) }
        case .alphabetical:
            return base.sorted { compareWords($0, $1) }
        case .dateAdded:
            return base.sorted { lhs, rhs in
                if lhs.effectiveDateAdded != rhs.effectiveDateAdded {
                    return lhs.effectiveDateAdded > rhs.effectiveDateAdded
                }
                return compareWords(lhs, rhs)
            }
        case .difficulty:
            return base.sorted { lhs, rhs in
                let lhsTier = tierPriority(lhs.difficultyTier)
                let rhsTier = tierPriority(rhs.difficultyTier)
                if lhsTier != rhsTier { return lhsTier < rhsTier }
                return compareWords(lhs, rhs)
            }
        }
    }

    private static func filterBySearch(
        _ entries: [VocabularyEntry],
        searchText: String
    ) -> [VocabularyEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.word.localizedCaseInsensitiveContains(searchText) ||
            $0.translation.localizedCaseInsensitiveContains(searchText)
        }
    }

    static func compareKnowledgeEntries(_ lhs: VocabularyEntry, _ rhs: VocabularyEntry, now: Date) -> Bool {
        if reviewPriority(lhs.reviewState(at: now)) != reviewPriority(rhs.reviewState(at: now)) {
            return reviewPriority(lhs.reviewState(at: now)) < reviewPriority(rhs.reviewState(at: now))
        }
        if lhs.nextReviewAt != rhs.nextReviewAt {
            return lhs.nextReviewAt < rhs.nextReviewAt
        }
        let lhsTier = tierPriority(lhs.difficultyTier)
        let rhsTier = tierPriority(rhs.difficultyTier)
        if lhsTier != rhsTier {
            return lhsTier < rhsTier
        }
        return compareWords(lhs, rhs)
    }

    /// Swift's `sorted` is not a stable-sort contract. Every sort branch must
    /// therefore end at the persisted UUID after comparing the visible word,
    /// otherwise two equal-looking cards can reorder between renders and make
    /// both lazy-list identity and Simulator evidence nondeterministic.
    private static func compareWords(_ lhs: VocabularyEntry, _ rhs: VocabularyEntry) -> Bool {
        let wordOrder = lhs.word.localizedCaseInsensitiveCompare(rhs.word)
        if wordOrder != .orderedSame {
            return wordOrder == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func reviewPriority(_ state: VocabularyReviewState) -> Int {
        switch state {
        case .due: return 0
        case .unlearned: return 1
        case .reviewed: return 2
        }
    }

    private static func tierPriority(_ tier: String?) -> Int {
        switch tier {
        case "core": return 0
        case "intermediate": return 1
        case "advanced": return 2
        case "rare": return 3
        default: return 4
        }
    }
}
