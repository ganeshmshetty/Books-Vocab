import Foundation
import Observation
import SwiftData

enum AddLinkActionError: Equatable {
    case missingSourceCard
    case missingTargetCard
    case duplicateLink
    case missingLink
    case invalidLink
    case existingLinkRefreshFailed
    case existingLinkFailed

    /// Stable code exposed on `addLink.error.reason`.
    var reason: String {
        switch self {
        case .missingSourceCard: return "missing_source_card"
        case .missingTargetCard: return "missing_target_card"
        case .duplicateLink: return "duplicate_link"
        case .missingLink: return "missing_link"
        case .invalidLink: return "invalid_link"
        case .existingLinkRefreshFailed: return "link_refresh_failed"
        case .existingLinkFailed: return "link_failed"
        }
    }

    /// Unsynced cards cannot be linked by retrying; everything else is transient.
    var isRetryable: Bool {
        switch self {
        case .missingSourceCard, .missingTargetCard, .duplicateLink: return false
        case .missingLink, .invalidLink, .existingLinkRefreshFailed, .existingLinkFailed: return true
        }
    }

    var message: String {
        switch self {
        case .missingSourceCard: return L10n.string("addLink.error.sourceNotSynced")
        case .missingTargetCard: return L10n.string("此單字尚未同步，無法建立連結")
        case .duplicateLink: return L10n.string("addLink.target.alreadyLinked")
        case .missingLink, .invalidLink: return L10n.string("addLink.error.invalidResponse")
        case .existingLinkRefreshFailed: return L10n.string("addLink.error.refreshFailed")
        case .existingLinkFailed: return L10n.string("addLink.error.linkFailed")
        }
    }
}

enum AddLinkActionPhase: Equatable {
    case idle
    case linking
    case succeeded
    case cancelled
    case failed
}

enum AddLinkLookupState: Equatable {
    case idle
    case results(count: Int)
    case empty
    case loading(attempt: Int)
    case error(attempt: Int)
    case retry(attempt: Int)

    var accessibilityValue: String {
        switch self {
        case .idle:
            return "idle"
        case .results(let count):
            return "results-\(count)"
        case .empty:
            return "empty"
        case .loading(let attempt):
            return "loading-attempt-\(attempt)"
        case .error(let attempt):
            return "error-attempt-\(attempt)"
        case .retry(let attempt):
            return "retry-attempt-\(attempt)"
        }
    }
}

enum AddLinkDetailMaterializationState: Equatable {
    case ready(senseCount: Int)
    case missingExample(senseCount: Int)
    case providerDecodeError
    case recovered(senseCount: Int)

    var accessibilityValue: String {
        switch self {
        case .ready(let senseCount):
            return "ready-senses-\(senseCount)"
        case .missingExample(let senseCount):
            return "missing-example-senses-\(senseCount)"
        case .providerDecodeError:
            return "provider-decode-error-retryable"
        case .recovered(let senseCount):
            return "recovered-senses-\(senseCount)"
        }
    }
}

struct AddLinkDetailProjection: Equatable {
    struct Sense: Equatable {
        let id: String
        let partOfSpeech: String?
        let definition: String
        let translation: String?
        let examples: [String]
    }

    struct Provenance: Equatable {
        let provider: String?
        let source: String
        let chapter: String?
        let context: String
    }

    let word: String
    let translation: String
    let senses: [Sense]
    let forms: [String]
    let provenance: Provenance
    let state: AddLinkDetailMaterializationState

    var hasMissingExample: Bool {
        senses.contains { $0.examples.isEmpty }
    }
}

private struct AddLinkDetailPayload: Decodable {
    let provider: String?
    let senses: [AddLinkDetailPayloadSense]
    let forms: [String]?
}

private struct AddLinkDetailPayloadSense: Decodable {
    let id: String?
    let partOfSpeech: String?
    let definition: String
    let translation: String?
    let examples: [String]?
}

private enum AddLinkDetailPayloadDecode {
    case plain
    case decoded(AddLinkDetailPayload)
    case malformed
}

@Observable @MainActor
final class AddLinkCoordinator {
    private(set) var actionPhase: AddLinkActionPhase = .idle
    private(set) var actionError: AddLinkActionError?
    private var actionTargetCardID: String?

    /// The optimistic placeholder of the link currently being created. `cancelAction()` rolls it
    /// back synchronously so the projection never outlives the `.cancelled` phase (#2196); the
    /// cancelled task's own rollback later becomes an idempotent no-op.
    private struct InFlightLink {
        let pending: VocabularyGraphLinkMutation.PendingManualLink
        let source: VocabularyEntry
        let generation: Int
    }

    private var actionGeneration = 0
    private var actionTask: Task<Void, Never>?
    private var actionTaskToken = 0
    @ObservationIgnored private var inFlightLink: InFlightLink?
    @ObservationIgnored private var lastRequest: (target: VocabularyEntry, source: VocabularyEntry, service: any GraphServing)?

    /// Card id of the row being linked right now (spinner on it, every row locked).
    var linkingTargetCardID: String? {
        actionPhase == .linking ? actionTargetCardID : nil
    }

    var canRetryLastAction: Bool {
        actionPhase == .failed && actionError?.isRetryable == true && lastRequest != nil
    }

    nonisolated static let candidateLimit = 20

    nonisolated static func localCandidates(
        query: String,
        sourceEntry: VocabularyEntry,
        allEntries: [VocabularyEntry],
        index: AddLinkSearchIndex = AddLinkSearchIndex()
    ) -> [VocabularyEntry] {
        // Same cleaning as the backend's `_clean_content` (trailing `.,;:!?`), so a
        // typed `run.` lists what `run` lists and the exact word is never hidden.
        let trimmed = AddLinkCreationCoordinator.cleanedQuery(query)
        guard !trimmed.isEmpty else { return [] }
        let linkedIDs = Set(sourceEntry.graphLinksByKind.values.flatMap { $0 }.map(\.cardId))
        index.syncLocale()
        let folded = AddLinkSearchIndex.fold(trimmed)
        // The exact word is listed first and kept even when 20+ partial matches
        // precede it in store order: Return links only an exact match (#2038), so
        // an exact word that fell outside the cap would be neither visible nor
        // linkable. Partial matches keep store order and fill the rest of the cap.
        let typed = AddLinkCreationCoordinator.normalizeWord(trimmed)
        var exact: [VocabularyEntry] = []
        var partial: [VocabularyEntry] = []
        for entry in allEntries {
            // Once the partial list is full only an exact word can still change the
            // result (it is kept beyond the cap), so every other entry is skipped
            // before any eligibility check or folding. The scan itself cannot stop:
            // an exact word may sit anywhere in store order, even twice.
            let partialFull = partial.count >= candidateLimit
            if partialFull, !index.isExactWord(entry, normalizedQuery: typed) { continue }
            guard Self.isEligibleTarget(entry, for: sourceEntry),
                  !(entry.kgCardId.map(linkedIDs.contains) ?? false),
                  index.matches(entry, foldedQuery: folded)
            else { continue }
            if partialFull || index.isExactWord(entry, normalizedQuery: typed) {
                exact.append(entry)
            } else {
                partial.append(entry)
            }
        }
        return Array((exact + partial).prefix(candidateLimit))
    }

    nonisolated static func lookupState(
        query: String,
        candidateCount: Int,
        creationPhase: AddLinkCreationPhase,
        creationAttempt: Int
    ) -> AddLinkLookupState {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return .idle }

        let attempt = max(creationAttempt, 1)
        switch creationPhase {
        case .running:
            return creationAttempt > 1
                ? .retry(attempt: attempt)
                : .loading(attempt: attempt)
        case .failed:
            return .error(attempt: attempt)
        default:
            return candidateCount > 0 ? .results(count: candidateCount) : .empty
        }
    }

    /// Accessibility value of a candidate row, collapsed or expanded. It names only what the
    /// collapsed row draws (word, translation, part of speech), whether the row is open, and the
    /// materialization verdict over every sense. Definitions, examples, forms and provenance are
    /// exposed only through the expanded hierarchy, never through the row value (#2407, #3111).
    nonisolated static func rowAccessibilityValue(
        for entry: VocabularyEntry,
        detail: AddLinkDetailProjection,
        isExpanded: Bool = false
    ) -> String {
        func normalized(_ value: String?) -> String {
            guard let value else { return "" }
            return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        var summary = [
            "word=\(normalized(entry.word))",
            "translation=\(normalized(entry.translation))"
        ]
        let partOfSpeech = normalized(detail.senses.first?.partOfSpeech)
        if !partOfSpeech.isEmpty {
            summary.append("pos=\(partOfSpeech)")
        }
        summary.append("expansion=\(isExpanded ? "expanded" : "collapsed")")
        summary.append("detail.state=\(detail.state.accessibilityValue)")
        if case .providerDecodeError = detail.state {
            summary.append("detail.recovery=retryable")
        }
        return summary.joined(separator: " | ")
    }

    /// One example line of the expanded row: the localized label, then the card's inline-markdown
    /// runs, so `**word**` draws as a highlight and never as literal asterisks (#3111).
    nonisolated static func exampleParagraph(for example: String) -> CardDocumentParagraph {
        CardDocumentParagraph(
            inlines: [CardDocumentInline.text(L10n.string("reviewCardLayout.field.example") + ": ")]
                + CardMarkdownInlineParser.parseParagraph(example).inlines
        )
    }

    nonisolated static func openCardIdentifier(for entry: VocabularyEntry) -> String {
        "\(detailIdentifier(for: entry)).openCard"
    }

    nonisolated static func linkIdentifier(for entry: VocabularyEntry) -> String {
        "\(detailIdentifier(for: entry)).link"
    }

    /// Full projection: every sense, example, form and provenance level.
    nonisolated static func dictionaryDetailProjection(
        for entry: VocabularyEntry,
        recoveringProviderError: Bool = false
    ) -> AddLinkDetailProjection {
        detailProjection(for: entry, recoveringProviderError: recoveringProviderError, senseLimit: nil)
    }

    /// Collapsed candidate row: the first sense only. `state` still counts every sense,
    /// so the row's materialization verdict matches the expanded view (#2407).
    nonisolated static func compactDetailProjection(
        for entry: VocabularyEntry,
        recoveringProviderError: Bool = false
    ) -> AddLinkDetailProjection {
        detailProjection(for: entry, recoveringProviderError: recoveringProviderError, senseLimit: 1)
    }

    /// What a candidate row materializes: the first sense while collapsed, the full projection once expanded.
    nonisolated static func candidateProjection(
        for entry: VocabularyEntry,
        isExpanded: Bool,
        recoveringProviderError: Bool = false
    ) -> AddLinkDetailProjection {
        isExpanded
            ? dictionaryDetailProjection(for: entry, recoveringProviderError: recoveringProviderError)
            : compactDetailProjection(for: entry, recoveringProviderError: recoveringProviderError)
    }

    private nonisolated static func detailProjection(
        for entry: VocabularyEntry,
        recoveringProviderError: Bool,
        senseLimit: Int?
    ) -> AddLinkDetailProjection {
        switch decodeDetailPayload(entry.explanation) {
        case .plain:
            return legacyDetailProjection(for: entry, state: nil)
        case .decoded(let payload):
            return payloadDetailProjection(payload, for: entry, senseLimit: senseLimit)
        case .malformed:
            if recoveringProviderError {
                return legacyDetailProjection(
                    for: entry,
                    state: .recovered(senseCount: 1),
                    useExplanation: false
                )
            }
            return AddLinkDetailProjection(
                word: entry.word,
                translation: entry.translation,
                senses: [],
                forms: formValues(for: entry, payloadForms: nil),
                provenance: provenance(for: entry, provider: nil),
                state: .providerDecodeError
            )
        }
    }

    nonisolated static func detailIdentifier(for entry: VocabularyEntry) -> String {
        "addLink.local.result.\(entry.kgCardId ?? entry.id.uuidString)"
    }

    nonisolated static func detailStateIdentifier(for entry: VocabularyEntry) -> String {
        "\(detailIdentifier(for: entry)).state"
    }

    nonisolated static func detailSenseIdentifier(for entry: VocabularyEntry, index: Int) -> String {
        "\(detailIdentifier(for: entry)).sense.\(index + 1)"
    }

    nonisolated static func detailExampleIdentifier(
        for entry: VocabularyEntry,
        senseIndex: Int,
        exampleIndex: Int
    ) -> String {
        "\(detailIdentifier(for: entry)).sense.\(senseIndex + 1).example.\(exampleIndex + 1)"
    }

    nonisolated static func detailMissingExampleIdentifier(
        for entry: VocabularyEntry,
        senseIndex: Int
    ) -> String {
        "\(detailIdentifier(for: entry)).sense.\(senseIndex + 1).example.missing"
    }

    nonisolated static func detailFormsIdentifier(for entry: VocabularyEntry) -> String {
        "\(detailIdentifier(for: entry)).forms"
    }

    nonisolated static func detailProvenanceIdentifier(for entry: VocabularyEntry) -> String {
        "\(detailIdentifier(for: entry)).provenance"
    }

    nonisolated static func detailRetryIdentifier(for entry: VocabularyEntry) -> String {
        "\(detailIdentifier(for: entry)).provider.retry"
    }

    private static let detailPayloadPrefix = "kg.dictionary.detail.v1:"

    private nonisolated static func decodeDetailPayload(
        _ explanation: String?
    ) -> AddLinkDetailPayloadDecode {
        guard let explanation,
              explanation.hasPrefix(detailPayloadPrefix) else {
            return .plain
        }
        let rawPayload = String(explanation.dropFirst(detailPayloadPrefix.count))
        guard let data = rawPayload.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AddLinkDetailPayload.self, from: data),
              !payload.senses.isEmpty,
              payload.senses.allSatisfy({ !$0.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .malformed
        }
        return .decoded(payload)
    }

    private nonisolated static func payloadDetailProjection(
        _ payload: AddLinkDetailPayload,
        for entry: VocabularyEntry,
        senseLimit: Int?
    ) -> AddLinkDetailProjection {
        // The verdict is taken over every sense; only the materialized list is limited.
        let senseCount = payload.senses.count
        let hasMissingExample = payload.senses.contains { cleanedValues($0.examples ?? []).isEmpty }
        let senses = payload.senses.prefix(senseLimit ?? senseCount).enumerated().map { index, value in
            AddLinkDetailProjection.Sense(
                id: cleaned(value.id) ?? "sense-\(index + 1)",
                partOfSpeech: cleaned(value.partOfSpeech) ?? cleaned(entry.partOfSpeech),
                definition: value.definition,
                translation: cleaned(value.translation) ?? cleaned(entry.translation),
                examples: cleanedValues(value.examples ?? [])
            )
        }
        let state: AddLinkDetailMaterializationState = hasMissingExample
            ? .missingExample(senseCount: senseCount)
            : .ready(senseCount: senseCount)
        return AddLinkDetailProjection(
            word: entry.word,
            translation: entry.translation,
            senses: senses,
            forms: formValues(for: entry, payloadForms: payload.forms),
            provenance: provenance(for: entry, provider: cleaned(payload.provider)),
            state: state
        )
    }

    private nonisolated static func legacyDetailProjection(
        for entry: VocabularyEntry,
        state: AddLinkDetailMaterializationState?,
        useExplanation: Bool = true
    ) -> AddLinkDetailProjection {
        let definition = (useExplanation ? cleaned(entry.explanation) : nil)
            ?? cleaned(entry.translation)
            ?? entry.word
        let senses = [
            AddLinkDetailProjection.Sense(
                id: "sense-1",
                partOfSpeech: cleaned(entry.partOfSpeech),
                definition: definition,
                translation: cleaned(entry.translation),
                examples: cleanedValues(entry.reviewExamples)
            )
        ]
        let resolvedState = state ?? (senses[0].examples.isEmpty
            ? .missingExample(senseCount: 1)
            : .ready(senseCount: 1))
        return AddLinkDetailProjection(
            word: entry.word,
            translation: entry.translation,
            senses: senses,
            forms: formValues(for: entry, payloadForms: nil),
            provenance: provenance(for: entry, provider: nil),
            state: resolvedState
        )
    }

    private nonisolated static func formValues(
        for entry: VocabularyEntry,
        payloadForms: [String]?
    ) -> [String] {
        var values = payloadForms ?? []
        if let rootForm = entry.rootForm { values.append(rootForm) }
        values.append(contentsOf: entry.inflections)
        return cleanedValues(values)
    }

    private nonisolated static func provenance(
        for entry: VocabularyEntry,
        provider: String?
    ) -> AddLinkDetailProjection.Provenance {
        AddLinkDetailProjection.Provenance(
            provider: provider,
            source: entry.bookTitle,
            chapter: cleaned(entry.chapterTitle),
            context: entry.context
        )
    }

    private nonisolated static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private nonisolated static func cleanedValues(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            guard let value = cleaned(value), !result.contains(value) else { continue }
            result.append(value)
        }
        return result
    }

    func linkExisting(
        target: VocabularyEntry,
        sourceEntry: VocabularyEntry,
        using service: any GraphServing
    ) async {
        guard !Task.isCancelled else { return }
        let generation = beginAction()
        actionTargetCardID = target.kgCardId
        guard sourceEntry.modelContext != nil,
              let sourceCardID = sourceEntry.kgCardId,
              Self.hasUsableCardID(sourceCardID) else {
            failAction(.missingSourceCard, generation: generation)
            return
        }
        guard let targetCardID = target.kgCardId,
              Self.hasUsableCardID(targetCardID) else {
            failAction(.missingTargetCard, generation: generation)
            return
        }
        guard Self.isEligibleTarget(target, for: sourceEntry) else {
            failAction(.existingLinkFailed, generation: generation)
            return
        }
        let alreadyLinked = sourceEntry.graphLinksByKind.values
            .flatMap { $0 }
            .contains { $0.cardId == targetCardID }
        guard !alreadyLinked else {
            actionPhase = .succeeded
            actionError = nil
            return
        }
        guard let pending = VocabularyGraphLinkMutation.beginManualLink(
            from: sourceEntry,
            to: target
        ) else {
            failAction(.existingLinkFailed, generation: generation)
            return
        }
        inFlightLink = InFlightLink(pending: pending, source: sourceEntry, generation: generation)
        defer {
            if inFlightLink?.generation == generation { inFlightLink = nil }
        }

        do {
            let link = try await service.createManualLink(
                fromId: sourceCardID,
                toId: pending.targetCardId,
                notebookId: sourceEntry.notebookId
            )
            try Task.checkCancellation()
            guard isCurrentAction(generation) else {
                VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
                return
            }
            guard !link.id.isEmpty else {
                VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
                failAction(.missingLink, generation: generation)
                return
            }
            guard link.fromId == sourceCardID, link.toId == targetCardID else {
                VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
                failAction(.invalidLink, generation: generation)
                return
            }
            VocabularyGraphLinkMutation.commitManualLink(pending, result: link, on: sourceEntry)
            actionPhase = .succeeded
            actionError = nil
        } catch is CancellationError {
            VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
            cancelCurrentAction(generation)
        } catch let error as KGError where Self.isConflict(error) {
            do {
                let links = try await service.pullGraphLinks(notebookId: sourceEntry.notebookId)
                try Task.checkCancellation()
                guard isCurrentAction(generation) else {
                    VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
                    return
                }
                guard let existingLink = links.first(where: {
                    $0.fromId == sourceCardID && $0.toId == targetCardID
                }) else {
                    throw KGError.serverError("Graph link refresh returned no matching link")
                }
                guard !existingLink.id.isEmpty else {
                    throw KGError.serverError("Graph link refresh returned an empty link id")
                }
                VocabularyGraphLinkMutation.commitManualLink(
                    pending,
                    result: existingLink,
                    on: sourceEntry
                )
                actionPhase = .succeeded
                actionError = nil
            } catch is CancellationError {
                VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
                cancelCurrentAction(generation)
            } catch {
                VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
                failAction(.existingLinkRefreshFailed, generation: generation)
            }
        } catch {
            VocabularyGraphLinkMutation.rollbackManualLink(pending, on: sourceEntry)
            failAction(.existingLinkFailed, generation: generation)
        }
    }

    /// Returns the spawned task so callers (tests) can await its teardown deterministically
    /// instead of guessing a number of `Task.yield()` hops.
    @discardableResult
    func startLinkExisting(
        target: VocabularyEntry,
        sourceEntry: VocabularyEntry,
        using service: any GraphServing
    ) -> Task<Void, Never> {
        // A second tap (same or another row) while a link is in flight must not
        // cancel and resend it; the rows are locked until it settles. The
        // in-flight task is returned so callers still await the real work.
        if actionPhase == .linking, let actionTask { return actionTask }
        cancelAction()
        lastRequest = (target, sourceEntry, service)
        actionTargetCardID = target.kgCardId
        actionPhase = .linking
        actionError = nil
        actionTaskToken += 1
        let taskToken = actionTaskToken
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.linkExisting(
                target: target,
                sourceEntry: sourceEntry,
                using: service
            )
            self.clearActionTask(taskToken: taskToken)
        }
        actionTask = task
        return task
    }

    /// Re-sends the last failed link when its error is transient.
    func retryLastAction() {
        guard canRetryLastAction, let lastRequest else { return }
        startLinkExisting(target: lastRequest.target, sourceEntry: lastRequest.source, using: lastRequest.service)
    }

    func cancelAction() {
        let wasRunning = actionPhase == .linking
        actionTaskToken += 1
        actionGeneration += 1
        actionTask?.cancel()
        actionTask = nil
        rollbackInFlightLink()
        guard wasRunning else { return }
        actionPhase = .cancelled
        actionError = nil
    }

    func cancel() {
        cancelAction()
    }

    private func beginAction() -> Int {
        actionGeneration += 1
        actionPhase = .linking
        actionError = nil
        return actionGeneration
    }

    private func rollbackInFlightLink() {
        guard let inFlight = inFlightLink else { return }
        inFlightLink = nil
        VocabularyGraphLinkMutation.rollbackManualLink(inFlight.pending, on: inFlight.source)
    }

    private func isCurrentAction(_ generation: Int) -> Bool {
        generation == actionGeneration && !Task.isCancelled
    }

    private func cancelCurrentAction(_ generation: Int) {
        guard generation == actionGeneration else { return }
        actionPhase = .cancelled
        actionError = nil
    }

    private func failAction(_ error: AddLinkActionError, generation: Int) {
        guard generation == actionGeneration else { return }
        actionPhase = .failed
        actionError = error
    }

    private func clearActionTask(taskToken: Int) {
        guard actionTaskToken == taskToken else { return }
        actionTask = nil
    }

    private nonisolated static func hasUsableCardID(_ cardID: String?) -> Bool {
        guard let cardID else { return false }
        return !cardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated static func isEligibleTarget(
        _ target: VocabularyEntry,
        for sourceEntry: VocabularyEntry
    ) -> Bool {
        target.id != sourceEntry.id
            && target.notebookId == sourceEntry.notebookId
            && target.kgCardId != sourceEntry.kgCardId
            && !target.isArchived
            && target.syncAction != .delete
            && hasUsableCardID(target.kgCardId)
    }

    private static func isConflict(_ error: KGError) -> Bool {
        guard case .httpError(let statusCode, _) = error else { return false }
        return statusCode == 409
    }
}
