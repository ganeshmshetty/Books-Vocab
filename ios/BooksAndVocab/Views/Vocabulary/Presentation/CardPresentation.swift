import Foundation

struct CardLinkGroupPresentation: Identifiable {
    let id: String
    let label: String
    let items: [KGCardLinkSummary]

    var overflowCount: Int { 0 }

    func shuffled() -> CardLinkGroupPresentation {
        CardLinkGroupPresentation(id: id, label: label, items: items.shuffled())
    }

    /// Stable partition that keeps links still being created in front, so a
    /// shuffle followed by the strip's per-presentation cut can never hide them
    /// behind "+N".
    func pendingFirst() -> CardLinkGroupPresentation {
        CardLinkGroupPresentation(
            id: id,
            label: label,
            items: items.filter(\.isPendingCreation) + items.filter { !$0.isPendingCreation }
        )
    }
}

struct CardPresentation {
    let kgCardId: String?
    let notebookId: String
    let word: String
    let translation: String
    let partOfSpeech: String?
    let difficultyTier: String?
    let reviewMode: VocabularyCardMode
    let examples: [String]
    let sourceContext: String
    let bookTitle: String
    let chapterTitle: String?
    let explanation: String?
    let collocations: [String]
    let forms: [String]
    let syncStatus: Int
    let dateAdded: Date
    let linkGroups: [CardLinkGroupPresentation]
    let activeLinkGroups: [CardLinkGroupPresentation]
    let document: CardDocument

    /// - Parameter pendingLinks: placeholders for links still being created.
    ///   `nil` reads the app-wide `PendingLinkProjection`; tests and previews pass
    ///   an explicit list to stay deterministic.
    /// - Parameter peerLookup: locally known peers by `kgCardId`. A link whose peer is
    ///   archived or queued for delete is dropped (#2535); unknown peers are kept.
    init(
        entry: VocabularyEntry,
        linkOrdering: [String] = Self.defaultLinkOrdering,
        pendingLinks: [KGCardLinkSummary]? = nil,
        peerLookup: [String: VocabularyEntry] = [:]
    ) {
        kgCardId = entry.kgCardId
        notebookId = entry.notebookId
        word = entry.word
        translation = entry.translation
        partOfSpeech = entry.partOfSpeech
        difficultyTier = entry.difficultyTier
        reviewMode = entry.reviewMode
        examples = entry.allReviewExamples
        sourceContext = entry.context
        bookTitle = entry.bookTitle
        chapterTitle = entry.chapterTitle
        explanation = entry.explanation
        collocations = entry.collocations
        syncStatus = entry.syncStatus
        dateAdded = entry.dateAdded

        forms = (entry.rootForm.map { [$0] } ?? []) + entry.inflections.filter { $0 != entry.rootForm }

        var grouped = entry.graphLinksByKind.mapValues { links in
            links.filter { link in
                guard let peer = peerLookup[link.cardId] else { return true }
                return !peer.isArchived && peer.syncAction != .delete
            }
        }
        let pending = pendingLinks ?? PendingLinkProjection.shared.links(forSourceCardID: entry.kgCardId)
        for placeholder in pending {
            // Pending items lead their group so they are never the ones pushed
            // into the "+N" overflow of the compact review strip.
            let existing = grouped[placeholder.kind] ?? []
            guard !existing.contains(where: { $0.id == placeholder.id }) else { continue }
            grouped[placeholder.kind] = [placeholder] + existing
        }
        linkGroups = linkOrdering.compactMap { kind in
            guard let items = grouped[kind], !items.isEmpty else { return nil }
            return CardLinkGroupPresentation(
                id: kind,
                // A placeholder's label is provisional; real siblings own the group label.
                label: items.first(where: { !$0.isPendingCreation })?.label ?? items.first?.label ?? kind,
                items: items
            )
        }

        activeLinkGroups = linkGroups.compactMap { group in
            let activeItems = group.items.filter { !$0.isHidden }
            guard !activeItems.isEmpty else { return nil }
            return CardLinkGroupPresentation(id: group.id, label: group.label, items: activeItems)
        }

        let computedSeparateSourceBlock = Self.separateSourceBlockShown(
            sourceContext: sourceContext, examples: examples, bookTitle: bookTitle
        )

        document = CardDocumentBuilder.build(
            word: word,
            translation: translation,
            partOfSpeech: partOfSpeech,
            difficultyTier: difficultyTier,
            reviewModeTitle: reviewMode.localizedTitle,
            examples: examples,
            sourceContext: sourceContext,
            bookTitle: bookTitle,
            chapterTitle: chapterTitle,
            explanation: explanation,
            collocations: collocations,
            showsSourceContext: computedSeparateSourceBlock
        )
    }

    var hiddenLinks: [KGCardLinkSummary] {
        linkGroups.flatMap(\.items).filter(\.isHidden)
    }

    var totalLinkCount: Int {
        activeLinkGroups.reduce(0) { $0 + $1.items.count }
    }

    /// 來源資訊是否可見（獨立來源區塊或書摘 footer 擇一承載）。
    var showsSourceContext: Bool {
        Self.computeShowsSourceContext(sourceContext: sourceContext, examples: examples, bookTitle: bookTitle)
    }

    /// 書摘 footer 的來源行。獨立來源區塊已承載時回 nil，避免同一組書名／章節印兩次。
    var exampleSource: CardExampleSource? {
        Self.separateSourceBlockShown(sourceContext: sourceContext, examples: examples, bookTitle: bookTitle)
            ? nil
            : CardExampleSource.make(bookTitle: bookTitle, chapterTitle: chapterTitle)
    }

    /// 獨立來源區塊：來源可見、且 context 與第一個例句不同（#3113 item 6）。
    /// 同一句已在例句區出現時，來源改由 footer 承載，不在 Linked Card 重印整句。
    static func separateSourceBlockShown(sourceContext: String, examples: [String], bookTitle: String) -> Bool {
        computeShowsSourceContext(sourceContext: sourceContext, examples: examples, bookTitle: bookTitle)
            && !sourceRepeatsExample(sourceContext: sourceContext, examples: examples)
    }

    /// sourceContext 是否需顯示 — 空白則否；否則僅當它與第一個例句不同、或書名非預設圖譜標題時才顯示。
    private static func computeShowsSourceContext(
        sourceContext: String,
        examples: [String],
        bookTitle: String
    ) -> Bool {
        let trimmed = sourceContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return examples.first?.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed
            || bookTitle != CardExampleSource.knowledgeGraphFallback
    }

    private static func sourceRepeatsExample(sourceContext: String, examples: [String]) -> Bool {
        let trimmed = sourceContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return examples.first?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
    }

    static let defaultLinkOrdering = ["contrasts_with", "shares_usage"]

    /// Review-session identity of a card (dateAdded + word). The one formula the
    /// review card, the deck presenter and session-transient UI state share, so a
    /// recycled resident slot can never be mistaken for the card it showed before.
    var reviewCardKey: String {
        "\(dateAdded.timeIntervalSinceReferenceDate)-\(word)"
    }
}

extension VocabularyEntry {
    var cardPresentation: CardPresentation {
        CardPresentation(entry: self)
    }

    func linkedEntry(for link: KGCardLinkSummary, in entries: [VocabularyEntry]) -> VocabularyEntry? {
        entries.first { $0.kgCardId == link.cardId }
    }

    func linkedEntry(for link: KGCardLinkSummary, lookup: [String: VocabularyEntry]) -> VocabularyEntry? {
        lookup[link.cardId]
    }

    static func buildCardIdLookup(from entries: [VocabularyEntry]) -> [String: VocabularyEntry] {
        var dict: [String: VocabularyEntry] = [:]
        dict.reserveCapacity(entries.count)
        for entry in entries {
            if let id = entry.kgCardId {
                dict[id] = entry
            }
        }
        return dict
    }
}
