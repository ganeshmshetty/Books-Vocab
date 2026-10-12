import Foundation

enum WordDetailPresentation {
    static func state(
        for entry: VocabularyEntry,
        in allEntries: [VocabularyEntry],
        lookup: [String: VocabularyEntry]? = nil,
        now: Date? = nil
    ) -> WordDetailPresenter.State {
        let effectiveLookup = lookup ?? VocabularyEntry.buildCardIdLookup(from: allEntries)
        let card = CardPresentation(entry: entry, peerLookup: effectiveLookup)
        let reviewReferenceDate = now ?? ReviewSettingsStore.shared.settings.reviewReferenceDate()

        return WordDetailPresenter.State(
            title: card.word,
            systemImage: "book.closed",
            card: card,
            rootForm: entry.rootForm,
            metadataItems: metadataItems(for: card),
            navigableLinkCardIDs: Set(
                card.linkGroups
                    .flatMap(\.items)
                    .compactMap { link in
                        effectiveLookup[link.cardId] == nil ? nil : link.cardId
                    }
            ),
            reviewProgress: entry.shouldAppearInReview
                ? reviewProgress(for: entry, now: reviewReferenceDate)
                : nil,
            collocationExplanations: entry.collocationExplanations
        )
    }

    private static func metadataItems(
        for card: CardPresentation
    ) -> [WordDetailPresenter.State.MetadataItem] {
        [
            .init(
                icon: "calendar",
                text: card.dateAdded.formatted(date: .abbreviated, time: .omitted)
            ),
            .init(
                icon: "link",
                text: L10n.format("vocab_graph_link_count_plural", Int64(card.totalLinkCount))
            ),
            syncMetadataItem(for: card.syncStatus)
        ]
    }

    private static func reviewProgress(
        for entry: VocabularyEntry,
        now: Date
    ) -> VocabReviewProgress {
        let state = entry.reviewState(at: now)

        switch state {
        case .unlearned:
            return VocabReviewProgress(
                statusLabel: L10n.string("未學習"),
                detailLabel: L10n.format("首輪 %@", entry.reviewIntervalHours.compactHourLabel),
                ratio: nil
            )
        case .due, .reviewed:
            let startDate = entry.lastReviewedAt ?? entry.dateAdded
            let interval = max(entry.nextReviewAt.timeIntervalSince(startDate), 60)
            let elapsed = max(0, now.timeIntervalSince(startDate))
            let ratio = max(elapsed / interval, 0)

            return VocabReviewProgress(
                statusLabel: state == .due ? L10n.string("待複習") : L10n.string("已複習"),
                detailLabel: "\(elapsed.compactReviewLabel) / \(interval.compactReviewLabel)",
                ratio: ratio
            )
        }
    }

    // MARK: - Sync metadata

    private static func syncMetadataItem(
        for syncStatus: Int
    ) -> WordDetailPresenter.State.MetadataItem {
        switch VocabularySyncState(rawValue: syncStatus) ?? .pending {
        case .synced:
            return .init(icon: "checkmark.circle", text: L10n.string("已同步"))
        case .failed:
            return .init(icon: "exclamationmark.circle", text: L10n.string("同步失敗"))
        case .pending:
            return .init(icon: "clock", text: L10n.string("待同步"))
        }
    }
}

// 緊湊時間標籤格式化見 CompactTimeFormatting.swift（與 WordRowPresentation 共用）。
