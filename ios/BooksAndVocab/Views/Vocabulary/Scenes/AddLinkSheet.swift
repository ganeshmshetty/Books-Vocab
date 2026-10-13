import SwiftUI
import SwiftData

/// Top-pill copy for Add Link outcomes (#2047). Each event has a stable key, so a
/// repeated outcome replaces the visible pill instead of stacking; detail and
/// actions stay in the in-sheet panel.
enum AddLinkToastEvent {
    static let actionFailedKey = "addLink.action.failed"
    static let creationFailedKey = "addLink.creation.failed"
    static let creationWarningKey = "addLink.creation.warning"
    static let blockedKey = "addLink.creation.blocked"

    static func actionFailed(_ error: AddLinkActionError) -> AppToastItem {
        AppToastItem(message: error.message, style: .error, key: actionFailedKey)
    }

    static func creationFailed(message: String) -> AppToastItem {
        AppToastItem(message: message, style: .error, key: creationFailedKey)
    }

    static func creationWarning(message: String) -> AppToastItem {
        AppToastItem(message: message, style: .warning, key: creationWarningKey)
    }

    static func blocked(message: String) -> AppToastItem {
        AppToastItem(message: message, style: .warning, key: blockedKey)
    }
}

struct AddLinkSheet: View {
    @ObserveInjection private var inject
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appSkin) private var appSkin
    @Environment(\.kgService) private var kgService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let sourceEntry: VocabularyEntry
    let allEntries: [VocabularyEntry]
    /// 多單字本入口才傳：候選只限來源同一本，sheet 要明講搜尋範圍（#2040）。
    var notebookScopeName: String? = nil
    var onLinked: () -> Void = {}
    /// Reports presentation to the hub, so a job finishing under an open sheet stays silent (#3116).
    private let creationHub: AddLinkCreationHub

    @State private var searchText = ""
    /// Folded search keys live as long as the sheet, so a keystroke does not re-fold the store (#2406).
    @State private var searchIndex = AddLinkSearchIndex()
    @State private var coordinator = AddLinkCoordinator()
    // Made by the hub, which keeps a running creation alive after this sheet closes.
    @State private var creationCoordinator: AddLinkCreationCoordinator
    @State private var creationAttempt = 0
    /// Only an outcome of a tap or retry the user just made earns a pill; a state
    /// restored on open (or by the hub) shows its panel without a pill (#2047).
    @State private var awaitingActionOutcome = false
    @State private var awaitingCreationOutcome = false
    @State private var didCompleteCreation = false
    @State private var recoveredProviderErrors: Set<UUID> = []
    /// One row open at a time; a query change closes it (#3111).
    @State private var rowDisclosure = AddLinkRowDisclosure()
    /// 打開卡片: the word's detail page, presented over this sheet so the query survives (#3111).
    @State private var openedCardEntry: VocabularyEntry?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.toastCoordinator) private var toastCoordinator
    @Environment(\.networkMonitor) private var networkMonitor
    /// Return on a word nothing in the notebook has: the create entry flashes (#2038).
    @State private var isCreateHighlighted = false
    @State private var createHighlightTask: Task<Void, Never>?
    // Names the notebook a new card lands in (the source card's own notebook).
    @Query(filter: #Predicate<Notebook> { !$0.isSoftDeleted })
    private var notebooks: [Notebook]

    init(
        sourceEntry: VocabularyEntry,
        allEntries: [VocabularyEntry],
        creationHub: AddLinkCreationHub = .shared,
        notebookScopeName: String? = nil,
        onLinked: @escaping () -> Void = {}
    ) {
        self.sourceEntry = sourceEntry
        self.allEntries = allEntries
        self.notebookScopeName = notebookScopeName
        self.onLinked = onLinked
        self.creationHub = creationHub
        _creationCoordinator = State(initialValue: creationHub.makeCoordinator())
    }

    private func lookupState(_ snapshot: AddLinkSearchSnapshot) -> AddLinkLookupState {
        AddLinkCoordinator.lookupState(
            query: searchText,
            candidateCount: snapshot.candidates.count,
            creationPhase: creationCoordinator.phase,
            creationAttempt: creationAttempt
        )
    }

    /// Display name of the notebook the created card is added to; never an id
    /// (same resolver the review card's notebook badge uses).
    private var createNotebookName: String {
        ReviewCardNotebookBadgeResolver.badge(for: sourceEntry.notebookId, notebooks: notebooks).name
    }

    private var connectivity: AddLinkConnectivity {
        AddLinkConnectivity(isConnected: networkMonitor.isConnected)
    }

    private var showsCreationProgress: Bool {
        creationCoordinator.phase == .running
            || creationCoordinator.phase == .failed
            || creationCoordinator.phase == .succeededWithWarnings
    }

    var body: some View {
        // One candidate computation per render; every reader below gets this value.
        let snapshot = AddLinkSearchSnapshot.make(
            query: searchText,
            sourceEntry: sourceEntry,
            allEntries: allEntries,
            index: searchIndex
        )
        let lookup = lookupState(snapshot)
        let returnBehavior = AddLinkReturnBehavior.resolve(snapshot)
        // Staged on purpose: one modifier chain over the whole body exceeds the
        // type checker's budget ("unable to type-check", AddLinkSheet.swift:204).
        let stack = NavigationStack {
            VStack(spacing: 0) {
                Text(lookup.accessibilityValue)
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("addLink.lookup.state")
                    .accessibilityValue(lookup.accessibilityValue)
                    .background(alignment: .topLeading) {
                        // What Return will do right now (#2038); read by UITests.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityIdentifier("addLink.return.action")
                            .accessibilityValue(returnBehavior.accessibilityValue)
                    }

                Text(L10n.format("addLink.sourceWord", sourceEntry.word))
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, appSkin.metrics.cardBlockPadding)
                    .accessibilityIdentifier("addLink.sourceWord")

                if let notebookScopeName {
                    Text(L10n.format("addLink.notebookScope", notebookScopeName))
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, appSkin.metrics.cardBlockPadding)
                        .accessibilityIdentifier("addLink.notebookScope")
                }

                if coordinator.actionPhase == .failed, !showsCreationProgress {
                    let actionError = coordinator.actionError ?? .existingLinkFailed
                    VocabStateMessageCard(
                        title: actionError.message,
                        systemImage: "exclamationmark.triangle"
                    ) {
                        if coordinator.canRetryLastAction {
                            Button(L10n.string("banner.action.retry")) {
                                awaitingActionOutcome = true
                                coordinator.retryLastAction()
                            }
                            .buttonStyle(.appCompactAction(.primary))
                            .accessibilityIdentifier("addLink.error.retry")
                        }
                    }
                    .transition(.statusRowReveal)
                    .padding(.horizontal, appSkin.metrics.cardBlockPadding)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("addLink.error.reason")
                    .accessibilityValue(actionError.reason)
                }

                if showsCreationProgress {
                    AddLinkCreationProgressView(
                        coordinator: creationCoordinator,
                        onRetry: retryCreation,
                        attempt: creationAttempt,
                        onDone: finishWithWarnings,
                        onBackToSearch: { creationCoordinator.acknowledge() }
                    )
                        .padding(.horizontal, appSkin.metrics.cardBlockPadding)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    searchField(returnBehavior, in: snapshot)
                        .padding(appSkin.metrics.cardBlockPadding)

                    List {
                        localSection(snapshot, returnBehavior: returnBehavior)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .vocabCanvasBackground()
            .animation(AppMotion.phaseChange, value: coordinator.actionPhase)
            .animation(AppMotion.phaseChange, value: creationCoordinator.phase)
            .navigationTitle(L10n.string("新增連結"))
            .inlineNavigationBarTitle()
            .toolbar { cancelToolbarContent }
        }
        let withPhaseHandlers = stack
            .onChange(of: coordinator.actionPhase) { _, phase in
                if phase == .failed, awaitingActionOutcome, let error = coordinator.actionError {
                    toastCoordinator.show(AddLinkToastEvent.actionFailed(error))
                }
                if phase != .linking { awaitingActionOutcome = false }
                if phase == .succeeded {
                    onLinked()
                    dismiss()
                }
            }
            .onChange(of: creationCoordinator.phase) { _, phase in
                announceCreationOutcome()
                // Only a full success closes on its own. A warning keeps the sheet
                // open (retry / done) so a partial result is never swallowed.
                guard phase == .succeeded, !didCompleteCreation else { return }
                didCompleteCreation = true
                onLinked()
                dismiss()
            }
            .onAppear {
                creationHub.sheetDidAppear(creationCoordinator)
                // Offline from the start: say so now, not after a failed round trip (#2039).
                if let notice = connectivity.noticeMessage { toastCoordinator.warning(notice) }
            }
        let withConnectionHandlers = withPhaseHandlers
            // A warning retry keeps the phase, so its outcome arrives as the retry ending.
            .onChange(of: creationCoordinator.isRetryingWarnings) { _, _ in
                announceCreationOutcome()
            }
            .onChange(of: networkMonitor.isConnected) { old, new in
                guard let message = AddLinkConnectivity.transitionMessage(
                    from: AddLinkConnectivity(isConnected: old),
                    to: AddLinkConnectivity(isConnected: new)
                ) else { return }
                if new { toastCoordinator.success(message) } else { toastCoordinator.warning(message) }
            }
            .onDisappear {
                createHighlightTask?.cancel()
                coordinator.cancel()
                creationHub.sheetDidDisappear(creationCoordinator)
                // A running creation is deliberately NOT cancelled: the hub owns it,
                // finishes the local projection, and the source card shows it as a
                // pending link meanwhile.
            }
            .onChange(of: searchText) { _, _ in
                rowDisclosure.send(.queryChanged)
            }
        withConnectionHandlers
            .toastSheet(item: $openedCardEntry) { entry in
                WordDetailSheet(entry: entry, allEntries: allEntries)
            }
            .enableInjection()
    }

    /// Own @ToolbarContentBuilder, so the toolbar closure is not solved inside the
    /// body's modifier chain.
    @ToolbarContentBuilder
    private var cancelToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.string("取消")) { dismiss() }
                .accessibilityIdentifier("addLink.cancel")
        }
    }

    private func localSection(
        _ snapshot: AddLinkSearchSnapshot,
        returnBehavior: AddLinkReturnBehavior
    ) -> some View {
        Section(L10n.string("addLink.localSection")) {
            if snapshot.isEmptyQuery {
                Text(L10n.string("輸入單字名稱來建立連結"))
                    .foregroundStyle(appSkin.palette.tertiaryText)
                    .accessibilityIdentifier("addLink.local.empty")
            } else {
                ForEach(snapshot.candidates) { entry in
                    // Collapsed rows materialize only the first sense; the full projection
                    // is built for the one row the user expanded (#2407, #3111).
                    let isExpanded = rowDisclosure.isExpanded(entry.id)
                    let recovering = recoveredProviderErrors.contains(entry.id)
                    let projection = AddLinkCoordinator.candidateProjection(
                        for: entry,
                        isExpanded: isExpanded,
                        recoveringProviderError: recovering
                    )
                    let isLinkingRow = entry.kgCardId != nil
                        && coordinator.linkingTargetCardID == entry.kgCardId
                    VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
                        candidateSummary(
                            entry,
                            projection: projection,
                            isExpanded: isExpanded,
                            isLinkingRow: isLinkingRow,
                            returnBehavior: returnBehavior,
                            snapshot: snapshot
                        )
                        if isExpanded {
                            expandedDetail(projection, for: entry)
                                .transition(.opacity)
                        }
                    }
                    .animation(AppMotion.contentFade, value: isExpanded)
                    .listRowBackground(Color.clear)
                }
                // Create stays reachable next to partial matches (`run` while
                // `running` is listed); otherwise it explains the exact match.
                if let targetState = snapshot.exactTargetState {
                    missingTargetSection(targetState, hasCandidates: !snapshot.candidates.isEmpty)
                }
            }
        }
    }

    /// Collapsed row (#3111): one line of word, part of speech and meaning, then two explicit
    /// buttons. A tap on the body only expands or collapses the row; linking and opening the
    /// card happen only through 新增連結 and 打開卡片.
    private func candidateSummary(
        _ entry: VocabularyEntry,
        projection: AddLinkDetailProjection,
        isExpanded: Bool,
        isLinkingRow: Bool,
        returnBehavior: AddLinkReturnBehavior,
        snapshot: AddLinkSearchSnapshot
    ) -> some View {
        let linkLocked = coordinator.linkingTargetCardID != nil
        // One line at default Dynamic Type; accessibility sizes may wrap word, POS and meaning to two (#3111).
        let lineCap = dynamicTypeSize.isAccessibilitySize ? 2 : 1
        return VStack(alignment: .leading, spacing: 0) {
            detailStateMarker(projection, for: entry)
            HStack(spacing: appSkin.spacing.inlineGap) {
                Button { send(.toggleRow(entry.id), in: snapshot) } label: {
                    HStack(spacing: appSkin.spacing.inlineGap) {
                        Text(entry.word)
                            .font(appSkin.typography.rowWord)
                            .foregroundStyle(appSkin.palette.primaryText)
                            .lineLimit(lineCap)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        if let partOfSpeech = projection.senses.first?.partOfSpeech {
                            Text(partOfSpeech)
                                .font(appSkin.typography.caption)
                                .foregroundStyle(appSkin.palette.tertiaryText)
                                .lineLimit(lineCap)
                                .fixedSize()
                        }
                        Text(entry.translation)
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.secondaryText)
                            .lineLimit(lineCap)
                            .truncationMode(.tail)
                        if isLinkingRow {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityIdentifier("addLink.row.linking.\(entry.kgCardId ?? "")")
                        }
                        Image(systemName: "chevron.down")
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The body tap is part of the same one-at-a-time link lock as 新增連結.
                .disabled(linkLocked)
                .accessibilityIdentifier(AddLinkCoordinator.detailIdentifier(for: entry))
                .accessibilityValue(
                    AddLinkCoordinator.rowAccessibilityValue(for: entry, detail: projection, isExpanded: isExpanded)
                )
                // VoiceOver reaches the same two actions the visible buttons carry.
                .accessibilityAction(named: Text(L10n.string("新增連結"))) {
                    send(.link(entry.id), in: snapshot)
                }
                .accessibilityAction(named: Text(L10n.string("打開卡片"))) {
                    send(.openCard(entry.id), in: snapshot)
                }

                // Return will link exactly this word (#2038). It sits outside the body button so
                // its identifier stays addressable.
                if !isLinkingRow, returnBehavior == .linkExact(entry.id) {
                    Image(systemName: "return")
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                        .accessibilityIdentifier("addLink.row.returnHint")
                        .transition(.opacity)
                }

                Button { send(.link(entry.id), in: snapshot) } label: {
                    Image(systemName: "link.badge.plus")
                        .font(appSkin.typography.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(appSkin.palette.secondaryText)
                // One link at a time: the button is locked while one is in flight.
                .disabled(linkLocked)
                .accessibilityLabel(L10n.string("新增連結"))
                .accessibilityIdentifier(AddLinkCoordinator.linkIdentifier(for: entry))

                Button { send(.openCard(entry.id), in: snapshot) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(appSkin.typography.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(appSkin.palette.secondaryText)
                .accessibilityLabel(L10n.string("打開卡片"))
                .accessibilityIdentifier(AddLinkCoordinator.openCardIdentifier(for: entry))
            }
            .animation(AppMotion.contentFade, value: returnBehavior)
        }
    }

    /// Hidden marker carrying the materialization verdict over every sense (UITests read it).
    private func detailStateMarker(_ projection: AddLinkDetailProjection, for entry: VocabularyEntry) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(AddLinkCoordinator.detailStateIdentifier(for: entry))
            .accessibilityValue(
                "\(projection.state.accessibilityValue)|senses=\(projection.senses.count)"
            )
    }

    /// Expanded row (#3111): every sense, examples through the card's inline-markdown pipeline
    /// (no literal `**`), forms, and provenance. The context line is dropped when it repeats the
    /// first example.
    @ViewBuilder
    private func expandedDetail(_ projection: AddLinkDetailProjection, for entry: VocabularyEntry) -> some View {
        let detailID = AddLinkCoordinator.detailIdentifier(for: entry)
        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
            switch projection.state {
            case .providerDecodeError:
                VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                    Text(L10n.string("sync.failure.reason.decoding"))
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("\(detailID).provider.error")
                    Button(L10n.string("重試")) {
                        recoveredProviderErrors.insert(entry.id)
                    }
                    .buttonStyle(.appCompactAction(.neutral))
                    .accessibilityIdentifier(AddLinkCoordinator.detailRetryIdentifier(for: entry))
                }
            case .ready, .missingExample, .recovered:
                ForEach(Array(projection.senses.enumerated()), id: \.offset) { senseIndex, sense in
                    senseDetail(sense, senseIndex: senseIndex, entry: entry, translation: projection.translation)
                }
            }

            if !projection.forms.isEmpty {
                Text(L10n.string("變化形") + ": " + projection.forms.joined(separator: ", "))
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.tertiaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .accessibilityIdentifier(AddLinkCoordinator.detailFormsIdentifier(for: entry))
            }

            let firstExample = projection.senses.first?.examples.first
            VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                Text(L10n.string("來源") + ": " + projection.provenance.source)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("\(detailID).provenance.source")
                if let chapter = projection.provenance.chapter {
                    Text(chapter)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("\(detailID).provenance.chapter")
                }
                let context = projection.provenance.context
                if !context.isEmpty, context != firstExample {
                    Text(context)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("\(detailID).provenance.context")
                }
            }
            .font(appSkin.typography.caption)
            .foregroundStyle(appSkin.palette.tertiaryText)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AddLinkCoordinator.detailProvenanceIdentifier(for: entry))
        }
        .padding(appSkin.metrics.cardBlockInnerGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            appSkin.palette.cardBackground,
            in: AppRoundedRect(roundness: AppRoundness.control)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(detailID).expanded")
    }

    private func senseDetail(
        _ sense: AddLinkDetailProjection.Sense,
        senseIndex: Int,
        entry: VocabularyEntry,
        translation: String
    ) -> some View {
        let senseID = AddLinkCoordinator.detailSenseIdentifier(for: entry, index: senseIndex)
        return VStack(alignment: .leading, spacing: AppSpacing.microGap) {
            if let partOfSpeech = sense.partOfSpeech {
                Text(L10n.string("reviewCardLayout.field.partOfSpeech") + ": " + partOfSpeech)
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("\(senseID).partOfSpeech")
            }
            // Expanded rows show the full definition; the collapsed row never builds this view.
            Text(sense.definition)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.secondaryText)
                .accessibilityIdentifier(senseID)
            if let senseTranslation = sense.translation, senseTranslation != translation {
                Text(senseTranslation)
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.tertiaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("\(senseID).translation")
            }
            if sense.examples.isEmpty {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(
                        AddLinkCoordinator.detailMissingExampleIdentifier(for: entry, senseIndex: senseIndex)
                    )
                    .accessibilityValue("missing")
            } else {
                ForEach(Array(sense.examples.enumerated()), id: \.offset) { exampleIndex, example in
                    CardInlineText(
                        paragraph: AddLinkCoordinator.exampleParagraph(for: example),
                        style: .example
                    )
                    .accessibilityIdentifier(
                        AddLinkCoordinator.detailExampleIdentifier(
                            for: entry,
                            senseIndex: senseIndex,
                            exampleIndex: exampleIndex
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Body tap, 新增連結 and 打開卡片 all route through the disclosure reducer: the reducer
    /// decides expansion, and the sheet performs the effect it names.
    private func send(_ action: AddLinkRowDisclosure.Action, in snapshot: AddLinkSearchSnapshot) {
        isSearchFocused = false
        // VoiceOver custom actions bypass a button's .disabled, so the lock is enforced here too.
        if case .link = action, coordinator.linkingTargetCardID != nil { return }
        switch rowDisclosure.send(action) {
        case .nothing:
            break
        case .link(let id):
            guard let entry = snapshot.candidates.first(where: { $0.id == id }) else { return }
            selectEntry(entry, in: snapshot)
        case .openCard(let id):
            guard let entry = snapshot.candidates.first(where: { $0.id == id }) else { return }
            openedCardEntry = entry
        }
    }

    @ViewBuilder
    private func missingTargetSection(
        _ targetState: AddLinkLocalTargetState,
        hasCandidates: Bool
    ) -> some View {
        switch targetState {
        case .missing:
            if kgService is any AddLinkOperationServing {
                AddLinkCreateRow(
                    title: AddLinkCreateCopy.title(target: searchText, source: sourceEntry.word),
                    notebookLine: AddLinkCreateCopy.notebookLine(notebookName: createNotebookName),
                    isHighlighted: isCreateHighlighted,
                    disabledReason: connectivity.createDisabledReason,
                    action: { startCreation() }
                )
                .transition(.opacity)
                .disabled(coordinator.linkingTargetCardID != nil || !connectivity.allowsServerWork)
                .listRowBackground(Color.clear)
            } else if !hasCandidates {
                Text(L10n.string("沒有結果"))
                    .foregroundStyle(appSkin.palette.tertiaryText)
            }
        case .pending, .failed:
            Text(L10n.string("此單字尚未同步，無法建立連結"))
                .foregroundStyle(appSkin.palette.tertiaryText)
        case .archived:
            Text(AddLinkCreationFailure(reason: "target_archived").message)
                .foregroundStyle(appSkin.palette.tertiaryText)
        case .active:
            // The exact match is a candidate row above; only explain when the
            // list could not show it.
            if !hasCandidates {
                Text(L10n.string("addLink.target.linkable"))
                    .foregroundStyle(appSkin.palette.tertiaryText)
            }
        case .linked:
            Text(L10n.string("addLink.target.alreadyLinked"))
                .foregroundStyle(appSkin.palette.tertiaryText)
                .accessibilityIdentifier("addLink.target.linked")
        case .source:
            Text(AddLinkCreationFailure(reason: "target_is_source").message)
                .foregroundStyle(appSkin.palette.tertiaryText)
        }
    }

    private func selectEntry(_ entry: VocabularyEntry, in snapshot: AddLinkSearchSnapshot) {
        guard snapshot.containsCandidate(entry) else { return }
        // Linking needs the server: refuse BEFORE the optimistic local write, so an
        // offline tap never flashes a link that is then rolled back (#2039).
        guard connectivity.allowsServerWork else {
            if let notice = connectivity.noticeMessage { toastCoordinator.warning(notice) }
            return
        }
        // #3115: an existing word takes the same operation pipeline as a new one (progress
        // panel, idempotent POST, hub ownership: closing the sheet does not roll it back).
        // The synchronous link is only the fallback for a service without operations.
        if kgService is any AddLinkOperationServing {
            startCreation(word: entry.word)
            return
        }
        awaitingActionOutcome = true
        coordinator.startLinkExisting(
            target: entry,
            sourceEntry: sourceEntry,
            using: kgService
        )
    }

    /// A warning retry re-runs only the unfinished parts (the link exists); a
    /// failure retry starts a new attempt under the key policy.
    private func retryCreation() {
        if creationCoordinator.phase == .succeededWithWarnings {
            awaitingCreationOutcome = true
            creationCoordinator.retryWarnings()
        } else {
            // Retry the job's own word: the search field may have changed since the attempt.
            startCreation(word: creationCoordinator.targetWord.isEmpty ? searchText : creationCoordinator.targetWord)
        }
    }

    /// Posts the pill for a creation outcome the user just caused, once. Running
    /// and a warning retry still in flight are not outcomes yet.
    private func announceCreationOutcome() {
        guard awaitingCreationOutcome, !creationCoordinator.isRetryingWarnings else { return }
        switch creationCoordinator.phase {
        case .failed:
            awaitingCreationOutcome = false
            if let message = creationCoordinator.message {
                toastCoordinator.show(AddLinkToastEvent.creationFailed(message: message))
            }
        case .succeededWithWarnings:
            awaitingCreationOutcome = false
            if let message = creationCoordinator.message {
                toastCoordinator.show(AddLinkToastEvent.creationWarning(message: message))
            }
        case .idle, .succeeded, .cancelled:
            awaitingCreationOutcome = false
        case .running, .blocked:
            break
        }
    }

    /// The user accepts a partial result: retire the job and close.
    private func finishWithWarnings() {
        guard !didCompleteCreation else { return }
        didCompleteCreation = true
        creationCoordinator.acknowledge()
        onLinked()
        dismiss()
    }

    private func startCreation() {
        startCreation(word: searchText)
    }

    /// Starts the one operation pipeline for a typed-new or an existing word (#3115).
    /// `word` is explicit so a candidate tap or a retry never resolves a partial query.
    private func startCreation(word: String) {
        guard let operationService = kgService as? any AddLinkOperationServing else { return }
        // Retry also lands here: offline must not turn into another failed attempt.
        guard connectivity.allowsServerWork else {
            if let notice = connectivity.noticeMessage { toastCoordinator.warning(notice) }
            return
        }
        creationAttempt += 1
        awaitingCreationOutcome = true
        creationCoordinator.start(
            word: word,
            sourceEntry: sourceEntry,
            allEntries: allEntries,
            operationService: operationService,
            syncService: kgService,
            container: modelContext.container
        )
        // Refused before any work starts: a one-off notice, so a pill (no panel).
        if creationCoordinator.phase == .blocked, let message = creationCoordinator.message {
            awaitingCreationOutcome = false
            toastCoordinator.show(AddLinkToastEvent.blocked(message: message))
        }
    }

    /// Return (#2038): links an exactly-typed existing word, otherwise only puts
    /// the keyboard away. It never creates and never picks among partial matches.
    private func submitSearch(_ behavior: AddLinkReturnBehavior, in snapshot: AddLinkSearchSnapshot) {
        switch behavior {
        case .linkExact(let id):
            guard let entry = snapshot.candidates.first(where: { $0.id == id }) else { return }
            isSearchFocused = false
            selectEntry(entry, in: snapshot)
        case .alreadyLinked:
            toastCoordinator.info(
                L10n.format("addLink.return.alreadyLinked", AddLinkCreateCopy.displayWord(snapshot.trimmedQuery))
            )
        case .dismissKeyboard:
            isSearchFocused = false
        case .revealCreate:
            isSearchFocused = false
            highlightCreateEntry()
        }
    }

    /// Briefly points at the create entry so the user sees where "create" lives.
    private func highlightCreateEntry() {
        createHighlightTask?.cancel()
        withAnimation(AppMotion.feedbackPulse) { isCreateHighlighted = true }
        createHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.feedbackPulse) { isCreateHighlighted = false }
        }
    }

    private func searchField(
        _ returnBehavior: AddLinkReturnBehavior,
        in snapshot: AddLinkSearchSnapshot
    ) -> some View {
        HStack(spacing: appSkin.metrics.cardBlockInnerGap) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(appSkin.palette.tertiaryText)
            TextField(L10n.string("搜尋單字…"), text: $searchText)
                .platformTextInputConfig()
                .submitLabel(returnBehavior.submitLabel)
                .onSubmit { submitSearch(returnBehavior, in: snapshot) }
                .focused($isSearchFocused)
                // Opening the sheet is the intent to search: no extra tap.
                .onAppear { isSearchFocused = true }
                .accessibilityIdentifier("addLink.searchField")
        }
        .padding(appSkin.metrics.cardBlockInnerGap * 1.5)
        .background(
            appSkin.palette.cardBackground,
            in: AppRoundedRect(roundness: AppRoundness.control)
        )
    }
}
