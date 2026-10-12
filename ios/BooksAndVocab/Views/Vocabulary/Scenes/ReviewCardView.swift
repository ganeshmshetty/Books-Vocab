import Observation
import SwiftUI

// MARK: - Data in

/// 畫一張複習卡所需要的全部資料。與複習 session 的互動狀態無關 —— 這是把卡片從
/// 「先造一個 presenter」的型別枷鎖裡解出來的那一刀。
struct ReviewCardContent {
    let card: CardPresentation
    let linkGroups: [ReviewCardLinkGroup]
    let backDocument: CardDocument
    /// Resident swipe slots copy this value type as cards advance. Keep the
    /// measurement state in the prepared card so the slot can be recycled
    /// without making the hidden probes cold again for every card.
    let measurementCache: ReviewCardMeasurementCache

    init(
        card: CardPresentation,
        linkGroups: [ReviewCardLinkGroup],
        backDocument: CardDocument,
        measurementCache: ReviewCardMeasurementCache = .init()
    ) {
        self.card = card
        self.linkGroups = linkGroups
        self.backDocument = backDocument
        self.measurementCache = measurementCache
    }
}

struct ReviewCardLinkGroup: Identifiable {
    let id: String
    let label: String
    let items: [KGCardLinkSummary]
    let overflowCount: Int
}

/// 卡片能發出的意圖。欄位全 optional；`.none` ＝ 純展示（設定頁預覽 / catalog），
/// 一顆 callback 都不接。
struct ReviewCardActions {
    var advanceReveal: (() -> Void)? = nil
    var collapseReveal: (() -> Void)? = nil
    var detailTap: (() -> Void)? = nil
    var linkTap: ((KGCardLinkSummary) -> Void)? = nil
    var addLink: (() -> Void)? = nil
    var explainCollocation: ((String) -> Void)? = nil
    var viewCollocationExplanation: ((String) -> Void)? = nil
    var deleteCollocationExplanation: ((String) -> Void)? = nil
    /// #2041：精簡卡的「暫時看詳細／恢復精簡」。nil（設定頁預覽 / catalog）＝不畫按鈕。
    var toggleTemporaryDetail: (() -> Void)? = nil

    static let none = ReviewCardActions()
}

/// Geometry observation must include card identity: a resident slot can replace
/// its content without changing the measured front height.
struct ReviewCardFrontMeasurement: Equatable {
    let height: CGFloat
    let cardKey: String
}

/// Section geometry must include card identity: a resident slot can replace
/// its content without changing the measured section height.
struct ReviewCardSectionMeasurement: Equatable {
    let height: CGFloat
    let cardKey: String
}

/// Geometry measured by a card belongs to the prepared card, not to the
/// resident view slot. `TodayReviewCardCache.prewarm` keeps the prepared-card
/// value for the lookahead window, so a recycled slot receives the same cache
/// when a card comes back without remounting its hidden probes.
@Observable
final class ReviewCardMeasurementCache {
    private(set) var naturalSectionHeights: [ReviewCardMeasurementKey: CGFloat] = [:]
    private(set) var intermediateSectionHeights: [ReviewCardMeasurementKey: CGFloat] = [:]
    private(set) var compactSectionHeights: [ReviewCardMeasurementKey: CGFloat] = [:]
    private(set) var measuredFrontHeight: CGFloat = 0
    private(set) var measuredFrontCardKey: String?

    func value(
        for key: ReviewCardMeasurementKey,
        level: ReviewCardLayoutSolver.MeasurementLevel
    ) -> CGFloat? {
        switch level {
        case .natural: naturalSectionHeights[key]
        case .intermediate: intermediateSectionHeights[key]
        case .compact: compactSectionHeights[key]
        }
    }

    func missingLevels(
        for key: ReviewCardMeasurementKey
    ) -> [ReviewCardLayoutSolver.MeasurementLevel] {
        ReviewCardLayoutSolver.missingMeasurementLevels(
            hasNatural: naturalSectionHeights[key] != nil,
            hasIntermediate: intermediateSectionHeights[key] != nil,
            hasCompact: compactSectionHeights[key] != nil
        )
    }

    @discardableResult
    func record(
        _ height: CGFloat,
        for key: ReviewCardMeasurementKey,
        level: ReviewCardLayoutSolver.MeasurementLevel
    ) -> Bool {
        guard height > 0 else { return false }
        switch level {
        case .natural:
            guard abs((naturalSectionHeights[key] ?? 0) - height) > 0.5 else { return false }
            naturalSectionHeights[key] = height
        case .intermediate:
            guard abs((intermediateSectionHeights[key] ?? 0) - height) > 0.5 else { return false }
            intermediateSectionHeights[key] = height
        case .compact:
            guard abs((compactSectionHeights[key] ?? 0) - height) > 0.5 else { return false }
            compactSectionHeights[key] = height
        }
        return true
    }

    /// Drops the graph-links section's measured heights (every variant, including
    /// the expanded ones) after the card's link items changed; every other section
    /// and the front height stay, so only the strip re-measures.
    func invalidateGraphLinksMeasurements() {
        naturalSectionHeights = naturalSectionHeights.filter { $0.key.section != .graphLinks }
        intermediateSectionHeights = intermediateSectionHeights.filter { $0.key.section != .graphLinks }
        compactSectionHeights = compactSectionHeights.filter { $0.key.section != .graphLinks }
    }

    @discardableResult
    func recordFront(_ measurement: ReviewCardFrontMeasurement) -> Bool {
        guard measurement.height > 0 else { return false }
        measuredFrontCardKey = measurement.cardKey
        guard abs(measuredFrontHeight - measurement.height) > 0.5 else { return false }
        measuredFrontHeight = measurement.height
        return true
    }
}

// MARK: - Review Card

/// 一張完整的複習卡：正面摺頁 ＋ 右上角 chrome ＋ 背面摺頁 ＋ 摺疊動畫。
///
/// 輸入全是資料。牌堆的事（slot transform、高度 cap、clipShape、geometryGroup、
/// zIndex、animation、gesture、DEBUG 幾何探針）留在 `TodayReviewSwipeDeck`，
/// 互動鎖由呼叫端算好後用 `interactive` 傳進來 —— 卡片內部不判 dismiss 相位。
///
/// `profile` 走參數而非 `@Environment(\.reviewCardLayoutStore)`：設定頁的即時預覽
/// 必須能餵一份尚未落地的 draft profile。
struct ReviewCardView: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.speechService) private var speechService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: ReviewCardContent
    let profile: ReviewCardLayoutProfile
    let viewport: ReviewCardViewport
    let showsAnswer: Bool
    /// #2041：這張精簡卡此刻暫時以詳細版面呈現。`profile` 仍是設定值（evidence 與
    /// 按鈕判斷讀它）；畫面讀 `renderProfile`。
    var temporarilyDetailed: Bool = false
    var mountsBack: Bool = true
    var interactive: Bool = true
    var borderOpacity: Double = TodayReviewMetrics.cardBorderActiveOpacity
    var measuresSections: Bool = true
    var collocationExplanations: [String: String] = [:]
    /// 多單字本入口才有值（`ReviewCardNotebookBadgeResolver`）；nil ＝ 不畫標示。
    var notebookBadge: ReviewCardNotebookBadge? = nil
    var actions: ReviewCardActions = .none
    var onFrontHeightChange: ((CGFloat) -> Void)? = nil

    /// 自量的寬度（量測 key 的 bucket）與正面高度（背面預算的被減數）。
    @State private var containerWidth: CGFloat = 393
    /// This is only a transient mount gate. The actual measurements live in
    /// `content.measurementCache`, which survives resident-slot recycling.
    @State private var measurementProbeReadyToken: String?
    /// 哪幾組知識連結被「+N」展開（#2043）。只活在記憶體、綁一張卡：常駐 slot 換卡後
    /// 舊卡的展開狀態讀不到，也不寫入任何 store。
    @State private var linkExpansion = ReviewCardLinkExpansion()

    private var reviewMeasurementCache: ReviewCardMeasurementCache { content.measurementCache }

    private var measurementProbeCardToken: String {
        "\(currentCardKey)|\(ObjectIdentifier(reviewMeasurementCache))"
    }

    private var measurementProbeTaskID: String {
        "\(measurementProbeCardToken)|interactive=\(interactive)|sections=\(measuresSections)"
    }

    private var shouldMountMeasurementProbes: Bool {
        measuresSections && interactive && measurementProbeReadyToken == measurementProbeCardToken
    }

    var body: some View {
        VStack(spacing: 0) {
            frontFoldSurface(
                content,
                showsAnswer: showsAnswer,
                interactive: interactive,
                borderOpacity: borderOpacity,
                viewport: viewport
            )
            .overlay(alignment: .topLeading) {
                // 單字本標示是 overlay，坐在正面既有的頂部留白裡：不進 layout，
                // 正面／背面高度與 solver 預算都不因它出現而變（#2040）。背面展開時
                // 正面仍在上方，所以兩面都看得到。
                if let notebookBadge {
                    notebookBadgeView(notebookBadge)
                }
            }
            .overlay(alignment: .topTrailing) {
                // chrome 常駐於每張卡（裝飾），只有互動中的那張可點 —— promote 時
                // chrome 不換樹、無「裸卡 pop」。
                frontCardChrome(content.card, interactive: interactive)
            }
            // 正面實測高度：背面預算的被減數，同時回吐給牌堆去填 slotFrontHeights。
            // 兩份量測只留這一份。
            .onGeometryChange(for: ReviewCardFrontMeasurement.self) {
                ReviewCardFrontMeasurement(height: $0.size.height, cardKey: currentCardKey)
            } action: { measurement in
                let height = measurement.height
                guard height > 0 else { return }
                // Update the identity even when two adjacent cards happen to have
                // the same height; otherwise the old key would keep this valid
                // measurement quarantined forever.
                reviewMeasurementCache.recordFront(measurement)
                // 一律回報、由牌堆對「slot 自己的上次值」去重：卡片量測快取只記這張卡
                // 的高度，卡回收進別的 slot 時快取值不變 → 舊寫法不回報，slot 殘留
                // 前一張卡的高度（#2026 stale 來源）。
                onFrontHeightChange?(height)
            }

            // 永遠存在於 view tree — PaperFoldModifier(Animatable) 直接驅動摺疊動畫。
            // frame(height: 0) 使摺疊時不佔 layout 空間，但內部 minHeight 使 view 仍以
            // 完整尺寸渲染（fold 視覺正確）。
            answerFoldSurface(content, viewport: viewport, mounted: mountsBack)
                .padding(.top, TodayReviewMetrics.stackLayerMicroOffset)
                .modifier(PaperFoldModifier(progress: showsAnswer ? 1 : 0))
                .frame(height: showsAnswer ? nil : 0, alignment: .top)
                .allowsHitTesting(ReviewFoldTapTargets.chevronEnabled(showsAnswer: showsAnswer))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            guard newWidth > 0, abs(containerWidth - newWidth) > 0.5 else { return }
            containerWidth = newWidth
        }
        .task(id: measurementProbeTaskID) {
            measurementProbeReadyToken = nil
            guard measuresSections, interactive else { return }
            let cardToken = measurementProbeCardToken
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, cardToken == measurementProbeCardToken else { return }
            measurementProbeReadyToken = cardToken
        }
        .enableInjection()
    }

    // MARK: Dimensions

    var reviewCardPadding: CGFloat { TodayReviewMetrics.foldPadding }
    var answerCardHeight: CGFloat { TodayReviewMetrics.answerMinHeight }

    /// 右上角 chrome 的總寬（喇叭 + 詳情，加上有項目時的 ⋯ 選單），供單字列保留
    /// trailing 空間，避免長詞被圖示擋住。與 frontCardChrome 同源：⋯ 是否出現由
    /// `hasCardMenu` 決定，因此保留寬度永不超過先前的最大值（#3112）。
    var frontChromeReserveWidth: CGFloat {
        Self.frontChromeReserve(
            buttons: Self.frontChromeBaseButtons + (hasCardMenu ? 1 : 0),
            gap: appSkin.spacing.inlineGap
        )
    }

    /// 喇叭 + 詳情：永遠可見。
    static let frontChromeBaseButtons = 2
    /// 右上角 chrome 上限：喇叭 + 詳情 + ⋯（#3112）。
    static let frontChromeMaxButtons = 3

    /// `buttons` 個 44pt HIG 觸控框、以 `gap` 相隔的寬度。純函式，供單元測試釘住保留寬度。
    static func frontChromeReserve(buttons: Int, gap: CGFloat) -> CGFloat {
        let count = CGFloat(buttons)
        return 44 * count + gap * (count - 1)
    }

    // MARK: Temporary Detail (#2041)

    /// The profile this card renders with: the persisted `profile`, with this
    /// card's direction lifted to `.standard` while temporarily detailed.
    private var renderProfile: ReviewCardLayoutProfile {
        ReviewCardTemporaryDetail.renderProfile(
            profile,
            mode: content.card.reviewMode,
            isDetailed: temporarilyDetailed
        )
    }

    /// Button state, read from the persisted profile. Hidden where no one can act
    /// on it (settings preview / catalog pass no callback).
    private var temporaryDetailToggle: ReviewCardTemporaryDetail.ToggleState {
        guard actions.toggleTemporaryDetail != nil else { return .unavailable }
        return ReviewCardTemporaryDetail.toggleState(
            profile: profile,
            mode: content.card.reviewMode,
            isDetailed: temporarilyDetailed
        )
    }

    /// The `⋯` menu is shown only when it has an item (the temporary-detail toggle
    /// today; #2042 adds the production toggle here). Without items it is absent
    /// rather than an empty menu, so standard-preset wrapping stays as it was (#3112).
    private var hasCardMenu: Bool { temporaryDetailToggle != .unavailable }

    /// Fields the detailed face would add, pre-measured by hidden probes while the
    /// card is still compact so the expansion animates to real heights.
    private func prospectiveDetailFields(face: ReviewCardFace) -> [ReviewCardField] {
        guard temporaryDetailToggle == .showDetail else { return [] }
        return ReviewCardTemporaryDetail.prospectiveBlockFields(
            profile: profile,
            mode: content.card.reviewMode,
            face: face,
            availability: reviewCardAvailability(for: content)
        )
    }

    @ViewBuilder
    private func prospectiveDetailProbes(
        _ currentCard: ReviewCardContent,
        face: ReviewCardFace
    ) -> some View {
        let fields = prospectiveDetailFields(face: face)
        if !fields.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(fields, id: \.self) { field in
                    reviewMeasurementProbes(field, currentCard: currentCard, face: face)
                }
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Front Surface

    /// 卡正面摺頁面。`showsAnswer` / `interactive` 由呼叫端投影（牌堆的 preview slot
    /// 恆 false），`borderOpacity` 由 `TodayReviewCardSlotLayout.borderOpacity` 內插
    /// （0.45 → 0.72），promote 翻面時邊框零 pop。`todayReview.card.front` a11y
    /// 識別子只掛在互動中的那張。
    func frontFoldSurface(
        _ currentCard: ReviewCardContent,
        showsAnswer: Bool,
        interactive: Bool,
        borderOpacity: Double,
        viewport: ReviewCardViewport
    ) -> some View {
        let card = currentCard.card
        let layout = reviewCardLayout(for: currentCard, face: .front, availableHeight: viewport.frontHeight)
        // `viewport.frontHeight` 是天花板，不是繪製高度：正面貼合解出的內容（保留
        // 120pt 地板），剩下的空間讓給 reveal zone / 背面，不再被貪婪 frame 吃掉一半。
        let drawnHeight = viewport.frontDrawnHeight(
            solvedContentHeight: layout.cardHeight,
            chrome: ReviewCardChrome.verticalInset(for: .front)
        )
        let _ = PerfLog.render.tick("todayReview.front.surface", "mode=\(card.reviewMode.rawValue)")
        // `interactive` 的 guard 必須留著：沒有它，設定頁預覽或 catalog 每次重繪都會
        // 吃掉複習畫面的 fling 計時器，兩個不相干的畫面互相污染。
        if interactive, let clock = TodayReviewState.flingClock {
            PerfLog.review.mark("front.gap", "w=\(card.word) \(PerfChannel.ms(since: clock))ms (fling->current-front body)")
            TodayReviewState.flingClock = nil
        }
        return ReviewFoldSurface(
            position: showsAnswer ? .top : .single,
            borderOpacity: borderOpacity
        ) {
            frontFaceContent(
                currentCard,
                layout: layout,
                drawnHeight: drawnHeight,
                measuresSections: shouldMountMeasurementProbes
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: drawnHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard ReviewFoldTapTargets.flipEnabled(showsAnswer: showsAnswer, interactive: interactive) else { return }
                actions.advanceReveal?()
            }
            // The face is an accessibility CONTAINER, not one merged element.
            // Without this declaration the `.accessibilityLabel` below has no
            // element to attach to, so SwiftUI synthesises one by MERGING the whole
            // face and pushes every property modifier down the subtree: VoiceOver
            // loses the face's own buttons (collocations / knowledge links / add
            // link) and `todayReview.card.front` gets republished on 2–3 nested
            // ~36pt buttons, so a UI-test query resolves a child instead of the card
            // box. Declared BEFORE the property modifiers so that identifier / label
            // / hint / action land on the container itself and stop propagating.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(interactive ? "todayReview.card.front" : "")
            .accessibilityLabel(L10n.format("複習卡片正面：%@", card.word))
            .accessibilityValue(evidenceIdentityValue(for: card))
            .accessibilityHint(showsAnswer || !interactive ? "" : "點一下翻轉卡片".localized)
            .accessibilityAction {
                guard ReviewFoldTapTargets.flipEnabled(showsAnswer: showsAnswer, interactive: interactive) else { return }
                actions.advanceReveal?()
            }
        }
    }

    @ViewBuilder
    private func frontFaceContent(
        _ currentCard: ReviewCardContent,
        layout: ReviewCardLayoutSolver.Result,
        drawnHeight: CGFloat,
        measuresSections: Bool
    ) -> some View {
        // 具體高度，不是上界：`.frame(maxHeight:)` 會把父層提案照單全收（彈性 frame
        // 是貪婪的），內容只有一行單字時也一樣。`drawnHeight` 由解出的內容推導，
        // 所以畫出來的高度與 solver 記帳的高度仍是同一個值。
        if layout.requiresScrollFallback {
            ScrollView(.vertical) {
                reviewCardFront(currentCard, layout: layout, measuresSections: measuresSections)
            }
                .frame(height: drawnHeight, alignment: .top)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("todayReview.card.front.content.scroll")
                .overlay(alignment: .topLeading) {
                    reviewEvidenceAnchor("todayReview.card.front.content.scroll")
                }
        } else {
            ViewThatFits(in: .vertical) {
                reviewCardFront(currentCard, layout: layout, measuresSections: measuresSections)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("todayReview.card.front.content.natural")
                    .overlay(alignment: .topLeading) {
                        reviewEvidenceAnchor("todayReview.card.front.content.natural")
                    }
                ScrollView(.vertical) {
                    reviewCardFront(currentCard, layout: layout, measuresSections: measuresSections)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("todayReview.card.front.content.scroll")
                .overlay(alignment: .topLeading) {
                    reviewEvidenceAnchor("todayReview.card.front.content.scroll")
                }
            }
            .frame(height: drawnHeight, alignment: .top)
        }
    }

    /// 卡片右上角 chrome（喇叭 / 詳情）。互動中的卡片與背後預覽**共用同一渲染**，
    /// 確保 fling 飛出期間背後預覽已帶完整 chrome、完成時的 swap 隱形（消除「裸卡 pop」）。
    /// `interactive=false`（預覽）時純裝飾：無動作、不可點。
    @ViewBuilder
    func frontCardChrome(_ card: CardPresentation, interactive: Bool) -> some View {
        HStack(spacing: appSkin.spacing.inlineGap) {
            // #3112：⋯ 只在有項目時出現（#2041 的暫時詳細現在收在選單裡）。放最左，
            // 喇叭 / 詳情（右上角）的位置不因它出現與否而移動。
            if hasCardMenu {
                cardMenu(interactive: interactive)
            }
            VocabChromeIconButton(
                systemImage: "speaker.wave.2.fill",
                label: "播放發音".localized,
                identifier: interactive ? "todayReview.card.speak" : nil,
                borderless: true,
                action: { if interactive { speechService.speak(card.word) } }
            )
            VocabChromeIconButton(
                systemImage: "arrow.up.right",
                label: "查看詳情".localized,
                identifier: interactive ? "todayReview.card.openDetail" : nil,
                borderless: true,
                action: { if interactive { actions.detailTap?() } }
            )
        }
        // The glyph sits centred in a 44pt touch box, so the box overhangs it by
        // `chromeHitOverhang`. Offsetting by the difference puts the visible glyph
        // `chromeCornerInset` from the card's top and trailing edges without
        // changing the word-row reserve (#3112).
        .offset(
            x: TodayReviewMetrics.chromeHitOverhang - TodayReviewMetrics.chromeCornerInset,
            y: TodayReviewMetrics.chromeCornerInset - TodayReviewMetrics.chromeHitOverhang
        )
        .allowsHitTesting(interactive)
    }

    /// 右上角 `⋯` 選單（#3112）。字形與喇叭／詳情同為 borderless：14pt、無框、44pt 觸控框。
    /// 非互動（預覽）時只畫字形，不掛 identifier、不回應點擊。
    @ViewBuilder
    private func cardMenu(interactive: Bool) -> some View {
        if interactive {
            Menu {
                Button {
                    actions.toggleTemporaryDetail?()
                } label: {
                    Label(
                        temporaryDetailToggle == .showDetail
                            ? L10n.string("todayReview.card.temporaryDetail.show")
                            : L10n.string("todayReview.card.temporaryDetail.restore"),
                        systemImage: temporaryDetailToggle == .showDetail
                            ? "rectangle.expand.vertical"
                            : "rectangle.compress.vertical"
                    )
                }
                .accessibilityIdentifier("todayReview.card.temporaryDetail")
                .accessibilityValue(temporaryDetailToggle.rawValue)
            } label: {
                cardMenuGlyph
            }
            .accessibilityLabel(L10n.string("todayReview.card.more"))
            .accessibilityIdentifier("todayReview.card.more")
            .accessibilityValue(temporaryDetailToggle.rawValue)
        } else {
            cardMenuGlyph
        }
    }

    private var cardMenuGlyph: some View {
        Image(systemName: "ellipsis")
            .font(appSkin.typography.iconSmall)
            .foregroundStyle(appSkin.palette.tertiaryText)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    /// 卡片所屬單字本（色點 ＋ 名稱）。純標示、不可點：點擊照常落到正面的翻卡手勢。
    /// 寬度讓出右上角 chrome；字級上限鎖住，確保在 Accessibility Dynamic Type 下仍
    /// 收在單字列上方的留白內、不壓到單字。
    func notebookBadgeView(_ badge: ReviewCardNotebookBadge) -> some View {
        HStack(spacing: AppSpacing.s1) {
            if badge.colorHex != nil {
                AppRoundedRect(roundness: AppRoundness.pill)
                    .fill(NotebookPalette.color(for: badge.colorHex))
                    .frame(
                        width: TodayReviewMetrics.notebookBadgeDotSize,
                        height: TodayReviewMetrics.notebookBadgeDotSize
                    )
            }
            Text(badge.name)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .padding(.top, TodayReviewMetrics.notebookBadgeTopInset)
        .padding(.leading, reviewCardPadding)
        .padding(.trailing, reviewCardPadding + frontChromeReserveWidth)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("todayReview.card.notebook.a11y", badge.name))
        .accessibilityIdentifier("todayReview.card.notebook")
        .accessibilityValue(badge.notebookId)
    }

    func reviewCardFront(
        _ currentCard: ReviewCardContent,
        layout: ReviewCardLayoutSolver.Result,
        measuresSections: Bool
    ) -> some View {
        let card = currentCard.card
        let plan = reviewCardRenderPlan(for: currentCard)
        let _ = PerfLog.review.mark("front.body", "w=\(card.word) answer=\(showsAnswer ? 1 : 0)")
        // Spacing comes from the solver's own arithmetic, never re-derived here.
        return VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s2) {
                switch card.reviewMode {
                case .recognition:
                    Text(card.word)
                        .font(reviewFrontWordFont(for: card.word))
                        .foregroundStyle(appSkin.palette.primaryText)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                case .production:
                    Text(card.translation)
                        .font(appSkin.typography.body.weight(.semibold))
                        .foregroundStyle(appSkin.palette.primaryTextMuted)
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Inline 欄位（詞性）與核心詞共用這條 firstTextBaseline —— 它是單字的
                // 附屬標註，不是自成一列的區塊。
                ForEach(plan.front.inlineFields, id: \.self) { field in
                    reviewOptionalField(
                        field,
                        currentCard: currentCard,
                        face: .front,
                        policy: layout.policy(for: .field(field))
                    )
                        .accessibilityIdentifier("todayReview.card.front.field.\(field.rawValue)")
                }
            }
            // 右上角 chrome（喇叭 / 詳情）是 overlay（必須在 reveal 手勢外才能獨立點），
            // 故在單字列保留其寬度的 trailing 空間，長詞（如 "be eaten alive"）在碰到
            // 圖示前先縮放 / 換行，不被擋字。
            .padding(.trailing, frontChromeReserveWidth)
            .onGeometryChange(for: ReviewCardSectionMeasurement.self) {
                ReviewCardSectionMeasurement(height: $0.size.height, cardKey: currentCardKey)
            } action: { measurement in
                recordReviewSectionHeight(
                    measurement.height,
                    currentCard: currentCard,
                    face: .front,
                    section: .core,
                    level: .natural
                )
            }

            ForEach(plan.front.blockFields, id: \.self) { field in
                reviewOptionalField(
                    field,
                    currentCard: currentCard,
                    face: .front,
                    policy: layout.policy(for: .field(field))
                )
                    .background {
                        if measuresSections {
                            reviewMeasurementProbes(
                                field,
                                currentCard: currentCard,
                                face: .front
                            )
                        }
                    }
                    .accessibilityIdentifier("todayReview.card.front.field.\(field.rawValue)")
                    .onGeometryChange(for: ReviewCardSectionMeasurement.self) {
                        ReviewCardSectionMeasurement(height: $0.size.height, cardKey: currentCardKey)
                    } action: { measurement in
                        recordReviewSectionHeight(
                            measurement.height,
                            currentCard: currentCard,
                            face: .front,
                            section: .field(field),
                            level: layout.policy(for: .field(field)).measurementLevel
                        )
                    }
            }
        }
        .background(alignment: .topLeading) {
            if measuresSections {
                prospectiveDetailProbes(currentCard, face: .front)
            }
        }
        .reviewCardFaceChrome(.front)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: layout.cardHeight, alignment: .topLeading)
    }

    // MARK: Combined Answer Surface

    /// 答案摺頁面。`mounted` 由呼叫端投影（牌堆只讓互動中的那張掛真內容，其餘恆 stub）。
    func answerFoldSurface(
        _ currentCard: ReviewCardContent,
        viewport: ReviewCardViewport,
        mounted: Bool
    ) -> some View {
        let card = currentCard.card
        let answerText = card.reviewMode == .production ? card.word : card.translation
        return ReviewFoldSurface(position: .bottom) {
            // Subtraction probe: while the FRONT card is shown the back tree
            // (CardDocumentView / CardRichTextRenderer / VocabTierLabel /
            // reviewLinkStrip) is NOT built — only a zero-cost stub holds the
            // folded slot. Mount is gated by the caller's mount gate, NOT by
            // `showsAnswer`: on reveal it mounts under the opening fold's opacity-0
            // cover; on collapse it STAYS mounted until the PaperFoldModifier
            // progress 1→0 finishes, so the fold folds the REAL content.
            // stub 用 answerCardHeight 撐 minHeight，與真內容同源，
            // 避免折疊→展開時 intrinsic 高度跳動。
            Group {
                if mounted {
                    // Identifier AND label on the MOUNTED branch only, for two
                    // reasons. (1) UI tests read `todayReview.card.back`.exists as
                    // the real flip-state signal (the folded stub deliberately
                    // carries none). (2) The label used to sit on the enclosing
                    // Group, i.e. on BOTH branches: it merged the mounted back into
                    // a single element — VoiceOver could not step through the
                    // knowledge links, collocations or the add-link button — and it
                    // also turned the folded stub into an element announcing the
                    // answer while the card was still face down. Same container rule
                    // as the front face: declare `.contain` first, then attach.
                    combinedAnswerContent(currentCard, viewport: viewport)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("todayReview.card.back")
                        .accessibilityLabel(L10n.format("翻譯：%@", answerText))
                        .accessibilityValue(evidenceIdentityValue(for: card))
                } else {
                    let _ = PerfLog.review.mark("back.stub", "w=\(card.word)")
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: answerCardHeight, alignment: .top)
                }
            }
        }
        .overlay(alignment: .top) {
            ReviewFoldChevronPill(
                action: { actions.collapseReveal?() },
                accessibilityLabel: L10n.string("todayReview.fold.collapse")
            )
            .offset(y: -TodayReviewMetrics.chevronButtonSize / 2)
        }
    }

    private func evidenceIdentityValue(for card: CardPresentation) -> String {
        let preset = profile.preset(for: card.reviewMode)
        let layoutProfile = "recognition:\(profile.recognition.rawValue),production:\(profile.production.rawValue)"
        // `preset` / `layoutProfile` stay the PERSISTED values; the transient
        // override is its own key (#2041) so evidence never mistakes it for a setting.
        // translationPrefix stays last: it is free text and may contain ';'.
        return "cardID=\(card.kgCardId ?? "missing");frontWord=\(card.word);mode=\(card.reviewMode.rawValue);preset=\(preset.rawValue);layoutProfile=\(layoutProfile);temporaryDetail=\(temporarilyDetailed ? 1 : 0);translationLength=\(card.translation.count);translationPrefix=\(card.translation.prefix(24))"
    }

    /// Stable machine-readable marker for the selected natural/scroll branch.
    /// Visible fields remain real descendants; this marker only identifies the
    /// presentation branch used by UI evidence.
    private func reviewEvidenceAnchor(_ identifier: String) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("")
    }

    func combinedAnswerContent(_ currentCard: ReviewCardContent, viewport: ReviewCardViewport) -> some View {
        let card = currentCard.card
        let _ = PerfLog.render.tick(
            "todayReview.answer.surface",
            "mode=\(card.reviewMode.rawValue) blocks=\(currentCard.backDocument.blocks.count)"
        )
        let plan = reviewCardRenderPlan(for: currentCard)
        // The outer insets are already out of `contentHeight`, so the front's
        // measured height is the only thing left to subtract — counting the insets
        // twice was the other half of the disagreeing-budget defect.
        //
        // 扣的是**這張卡自己**量到的正面高度。行為與扣牌堆的 activeCardHeight 等價：
        // 背面只有互動中的那張會 mount，而 activeShellHeight 回傳的就是那一格的高度。
        let backAvailableHeight = viewport.backHeight(
            frontOccupied: ReviewCardViewport.frontOccupiedHeight(
                measuredCardKey: reviewMeasurementCache.measuredFrontCardKey,
                currentCardKey: currentCardKey,
                measuredHeight: reviewMeasurementCache.measuredFrontHeight
            ) + TodayReviewMetrics.stackLayerMicroOffset
        )
        let layout = reviewCardLayout(for: currentCard, face: .back, availableHeight: backAvailableHeight)
        let maxHeight = max(backAvailableHeight, 1)
        return Group {
            switch layout.backPresentation {
            case .natural:
                answerContent(currentCard, plan: plan, layout: layout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("todayReview.card.back.content.natural")
                    .overlay(alignment: .topLeading) {
                        reviewEvidenceAnchor("todayReview.card.back.content.natural")
                    }
            case .scroll:
                ScrollView(.vertical) {
                    answerContent(currentCard, plan: plan, layout: layout)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("todayReview.card.back.content.scroll")
                .overlay(alignment: .topLeading) {
                    reviewEvidenceAnchor("todayReview.card.back.content.scroll")
                }
            }
        }
    }

    @ViewBuilder
    private func answerContent(
        _ currentCard: ReviewCardContent,
        plan: ReviewCardRenderPlan,
        layout: ReviewCardLayoutSolver.Result
    ) -> some View {
        let card = currentCard.card
        // Same rule as the front face: draw the gap the solver charged.
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {

            // 難度徽章畫在答案字**上方**、右對齊 —— 出貨版一直是這樣（見
            // a5885e228^ 的 combinedAnswerContent）。canonicalOrder 救不了這件事：
            // 它只排 field 彼此的先後，排不了 field 與 core 的先後。
            reviewBackFieldColumn(
                blockFields: plan.back.aboveCore,
                currentCard: currentCard,
                layout: layout
            )

            // Answer word + its section rule form ONE core section: the rule is the
            // core's own chrome (as on the shipped card), so it is measured with the
            // core rather than competing with the profile's fields for a slot.
            VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                // 背面與正面對稱：inline 欄位貼著答案字，不自成一列。排除是
                // face-agnostic 的，只修正面會讓「背面開了詞性」這個組合直接掉字。
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s2) {
                    Group {
                        if card.reviewMode == .production {
                            Text(card.word)
                        } else {
                            Text(card.translation)
                        }
                    }
                    .font(reviewAnswerWordFont(for: card.reviewMode == .production ? card.word : card.translation))
                    .foregroundStyle(appSkin.palette.primaryText)
                    .lineLimit(3)
                    .minimumScaleFactor(0.65)
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(plan.back.inlineFields, id: \.self) { field in
                        reviewOptionalField(
                            field,
                            currentCard: currentCard,
                            face: .back,
                            policy: layout.policy(for: .field(field))
                        )
                    }
                }

                // 這條線的規則是「答案底下還有東西才畫」。難度搬到上面之後，若使用者
                // 只開難度，底下已無內容 —— 再畫就是憑空多一條懸空分隔線。
                if ReviewCardLayoutSolver.drawsAnswerDivider(fields: plan.back.belowCore) {
                    CardSectionDivider(horizontalPadding: 0)
                }
            }
            .onGeometryChange(for: ReviewCardSectionMeasurement.self) {
                ReviewCardSectionMeasurement(height: $0.size.height, cardKey: currentCardKey)
            } action: { measurement in
                recordReviewSectionHeight(
                    measurement.height,
                    currentCard: currentCard,
                    face: .back,
                    section: .core,
                    level: .natural
                )
            }

            reviewBackFieldColumn(
                blockFields: plan.back.belowCore,
                currentCard: currentCard,
                layout: layout
            )
        }
        .background(alignment: .topLeading) {
            prospectiveDetailProbes(currentCard, face: .back)
        }
        .reviewCardFaceChrome(.back)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: layout.cardHeight, alignment: .topLeading)
    }

    /// 背面的一整欄 block 欄位。
    ///
    /// **body 只能是那個 ForEach**，不可包一層 VStack / Group-with-spacing：solver 收的是
    /// `max(sections.count - 1, 0)` 個 gap，而 ForEach 在 VStack 裡是攤平的（core + n 個
    /// 欄位 = n+1 個 sibling / n 個 gap）。包一層會讓外層只剩三個 sibling（兩個 gap）
    /// ＋內層自帶 spacing，畫出來的間距與 solver 記帳的間距當場分家；而且 aboveCore 為空
    /// 時 ForEach 貢獻 0 個 child，包 VStack 則多一個高度 0 卻仍吃一個 gap 的幽靈 child。
    @ViewBuilder
    private func reviewBackFieldColumn(
        blockFields: [ReviewCardField],
        currentCard: ReviewCardContent,
        layout: ReviewCardLayoutSolver.Result
    ) -> some View {
        // id: \.element 維持原本 id: \.self 的 view identity（不要換成 \.offset）。
        ForEach(Array(blockFields.enumerated()), id: \.element) { index, field in
            // rule 畫在欄位**前面**、當 VStack 的同層 sibling —— 不包進被量測的子樹，
            // 否則 natural 含線、隱藏 probe 量的另外兩階不含，階梯一壓縮就再度出現
            // 「solver 相信的高度 != 畫面畫的高度」。
            if ReviewCardLayoutSolver.drawsFieldDivider(face: .back, atIndex: index) {
                CardSectionDivider(horizontalPadding: 0)
            }

            reviewOptionalField(
                field,
                currentCard: currentCard,
                face: .back,
                policy: layout.policy(for: .field(field))
            )
                .background {
                    reviewMeasurementProbes(
                        field,
                        currentCard: currentCard,
                        face: .back
                    )
                }
                .onGeometryChange(for: ReviewCardSectionMeasurement.self) {
                    ReviewCardSectionMeasurement(height: $0.size.height, cardKey: currentCardKey)
                } action: { measurement in
                    recordReviewSectionHeight(
                        measurement.height,
                        currentCard: currentCard,
                        face: .back,
                        section: .field(field),
                        level: layout.policy(for: .field(field)).measurementLevel
                    )
                }
                // Keep the field selector as a container. Without explicit AX
                // containment, SwiftUI may promote the wrapper identifier onto
                // its child Button and erase `todayReview.card.link.<cardID>`.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("todayReview.card.back.field.\(field.rawValue)")
        }
    }

    // MARK: Link Strip

    func reviewLinkStrip(
        _ groups: [ReviewCardLinkGroup],
        presentation: ReviewCardLayoutSolver.GraphLinkPresentation = .twoPerGroup
    ) -> some View {
        HStack(alignment: .top, spacing: appSkin.spacing.inlineGap) {
            Image(systemName: "paperclip")
                .font(appSkin.typography.iconTiny)
                .foregroundStyle(appSkin.palette.tertiaryText)
                .padding(.top, TodayReviewMetrics.answerHintTopPadding)

            VStack(alignment: .leading, spacing: appSkin.spacing.inlineGap) {
                ForEach(groups) { group in
                    linkGroupRow(group, presentation: presentation)
                }
            }

            Spacer()

            // 圖示放大一級；可點範圍 ≥44pt 但不佔版面，連結區高度不變（#2044）。
            ReviewCardHitTargetButton(
                action: { actions.addLink?() },
                accessibilityIdentifier: "todayReview.card.addLink",
                accessibilityLabel: L10n.string("vocab.card.addLink")
            ) {
                Image(systemName: "plus")
                    .font(appSkin.typography.iconMedium)
                    .foregroundStyle(appSkin.palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One group of the strip: label, the links that fit beside it, and a "+N"
    /// that is a real control — it expands the group in place (every link, wrapped
    /// below the label) and collapses it again (#2043).
    @ViewBuilder
    private func linkGroupRow(
        _ group: ReviewCardLinkGroup,
        presentation: ReviewCardLayoutSolver.GraphLinkPresentation
    ) -> some View {
        let isExpanded = linkExpansion.isExpanded(group.id, cardKey: currentCardKey)
        let row = ReviewCardLinkStripLayout.row(for: group, presentation: presentation, isExpanded: isExpanded)
        let shown = row.visible
        // One flow for both states (#3114): the label is the hanging-indent cell, and
        // each chip carries its own " | " so a separator never starts a line.
        HangingIndentFlowLayout(spacing: AppSpacing.s1) {
            Text(group.label.localized + "：")
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)

            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: AppSpacing.s1) {
                    linkItemButton(item)
                    if index < shown.count - 1 {
                        Text("|")
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.quaternaryText)
                    }
                }
            }

            if row.isExpandable {
                if isExpanded, row.overflowCount > 0 {
                    overflowCountText(row.overflowCount)
                }
                linkOverflowToggle(group, row: row, isExpanded: isExpanded)
            } else if row.overflowCount > 0 {
                // Links the device does not hold: counted, but nothing to expand.
                overflowCountText(row.overflowCount)
            }
        }
    }

    private func overflowCountText(_ count: Int) -> some View {
        Text("+\(count)")
            .font(appSkin.typography.caption)
            .foregroundStyle(appSkin.palette.quaternaryText)
    }

    /// One tappable link (a pending placeholder explains what is happening instead).
    @ViewBuilder
    private func linkItemButton(_ item: KGCardLinkSummary) -> some View {
        if let creationState = item.pendingCreationState {
            pendingCreationLinkButton(item, state: creationState)
        } else {
            Button { actions.linkTap?(item) } label: {
                Text(item.word)
                    .font(appSkin.typography.monoEmphasis)
                    .foregroundStyle(appSkin.palette.primaryText)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("todayReview.card.link.\(item.cardId)")
        }
    }

    /// "+N" (collapsed) / "收合" (expanded), drawn as a chevron capsule so it reads as a
    /// control. The 44pt touch target overlays the capsule and does not grow the row (#3114).
    private func linkOverflowToggle(
        _ group: ReviewCardLinkGroup,
        row: ReviewCardLinkStripLayout.Row,
        isExpanded: Bool
    ) -> some View {
        let cardKey = currentCardKey
        let reducesMotion = reduceMotion
        return ReviewCardHitTargetButton(
            minimumSide: TodayReviewMetrics.linkOverflowHitTarget,
            action: {
                let animation: Animation? = reducesMotion ? nil : AppMotion.reviewRevealSpring
                withAnimation(animation) {
                    linkExpansion.toggle(group.id, cardKey: cardKey)
                }
            },
            accessibilityIdentifier: "todayReview.card.link.overflow.\(group.id)",
            // #3227：收合時「+N」是純符號文字，VoiceOver 需要「顯示其餘 N 個連結」；展開時沿用可見的「收合」文案。
            accessibilityLabel: isExpanded ? nil : L10n.format("todayReview.card.link.overflow.a11y", "\(row.overflowCount)"),
            accessibilityValue: isExpanded ? "expanded" : "collapsed"
        ) {
            HStack(spacing: AppSpacing.s1) {
                Text(isExpanded ? L10n.string("todayReview.card.link.collapse") : "+\(row.overflowCount)")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(appSkin.typography.iconTiny)
                    .accessibilityHidden(true)
            }
            .font(appSkin.typography.caption)
            .foregroundStyle(appSkin.palette.secondaryText)
            .padding(.horizontal, AppSpacing.s2)
            .padding(.vertical, AppSpacing.s1)
            .background(AppRoundedRect(roundness: appSkin.roundness.pill).fill(appSkin.palette.cardBorder))
        }
    }

    /// A link whose target card is still being created. It is a real, tappable
    /// strip item (the tap explains what is happening) rather than a spinner
    /// overlay, so it keeps the strip's single-line height.
    private func pendingCreationLinkButton(
        _ item: KGCardLinkSummary,
        state: KGCardLinkSummary.CreationState
    ) -> some View {
        Button { actions.linkTap?(item) } label: {
            HStack(spacing: AppSpacing.s1) {
                Text(item.word)
                    .font(appSkin.typography.monoEmphasis)
                    .foregroundStyle(appSkin.palette.primaryText)
                    .lineLimit(1)
                switch state {
                case .creating:
                    ProgressView()
                        .controlSize(.mini)
                    Text(L10n.string("todayReview.link.pending.creating"))
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                        .lineLimit(1)
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                        .font(appSkin.typography.iconTiny)
                        .foregroundStyle(appSkin.palette.destructive)
                case .warning:
                    Image(systemName: "exclamationmark.circle")
                        .font(appSkin.typography.iconTiny)
                        .foregroundStyle(appSkin.palette.warning)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("todayReview.card.link.pending.\(item.word)")
        .accessibilityValue(state.rawValue)
    }

    /// Shown by the graph-links section when the card has no links yet. It is the
    /// only place the review card can create its first link, which is why the
    /// section is always *available* even though its content is empty.
    private var addLinkPrompt: some View {
        HStack(spacing: 0) {
            // 可點範圍 ≥44pt 高，版面仍只佔一行 caption（#2044）。
            ReviewCardHitTargetButton(
                action: { actions.addLink?() },
                accessibilityIdentifier: "todayReview.card.addLink"
            ) {
                HStack(spacing: appSkin.spacing.inlineGap) {
                    Image(systemName: "plus")
                        .font(appSkin.typography.iconSmall)
                    Text("新增連結".localized)
                        .font(appSkin.typography.caption)
                }
                .foregroundStyle(appSkin.palette.tertiaryText)
            }
        }
        // The field wrapper receives `todayReview.card.back.field.graphLinks`
        // from the caller. Keep it as a real AX container so the child action
        // remains independently addressable as `todayReview.card.addLink`.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Render Plan / Adaptive Layout

    private func reviewCardRenderPlan(for currentCard: ReviewCardContent) -> ReviewCardRenderPlan {
        .make(
            profile: renderProfile,
            mode: currentCard.card.reviewMode,
            availability: reviewCardAvailability(for: currentCard)
        )
    }

    private func reviewCardAvailability(for currentCard: ReviewCardContent) -> ReviewCardContentAvailability {
        let card = currentCard.card
        return .forReviewCard(
            partOfSpeech: card.partOfSpeech,
            difficultyTier: card.difficultyTier,
            exampleCount: card.examples.count,
            explanationParagraphCount: currentCard.backDocument.meaningParagraphs().count,
            collocationCount: card.collocations.count
        )
    }

    private func reviewCardLayout(
        for currentCard: ReviewCardContent,
        face: ReviewCardFace,
        availableHeight: CGFloat
    ) -> ReviewCardLayoutSolver.Result {
        let plan = reviewCardRenderPlan(for: currentCard)
        // 只有 block 欄位向 solver 要一格預算。inline 欄位（詞性）畫在核心列裡，
        // 高度已經被 `.core` 的 onGeometryChange 量進去了。
        let fields = face == .front ? plan.front.blockFields : plan.back.blockFields
        // 同一組 blockFields 的兩欄分割（core 之上／之下）。hairline 逐欄記帳：
        // 一欄的第一格貼的是 core 不是另一格，接起來算 n-1 會多收一條。
        let columns = face == .front
            ? [plan.front.aboveCore, plan.front.belowCore]
            : [plan.back.aboveCore, plan.back.belowCore]
        let defaults: [ReviewCardLayoutSolver.Section: ReviewCardLayoutSolver.Measurement] = [
            .core: .init(naturalHeight: face == .front ? 112 : 132),
            .field(.partOfSpeech): .init(naturalHeight: 22),
            .field(.difficultyTier): .init(naturalHeight: 24),
            .field(.example): .init(naturalHeight: 88, compactHeight: 44),
            .field(.explanation): .init(naturalHeight: 66, intermediateHeight: 44, compactHeight: 22),
            .field(.collocations): .init(naturalHeight: 64, intermediateHeight: 48, compactHeight: 32),
            .field(.graphLinks): .init(naturalHeight: 72, intermediateHeight: 48, compactHeight: 20)
        ]
        let sections = [ReviewCardLayoutSolver.Section.core] + fields.map(ReviewCardLayoutSolver.Section.field)
        let measurements = Dictionary(uniqueKeysWithValues: sections.map { section in
            let key = reviewMeasurementKey(for: currentCard, face: face, section: section)
            let fallback = defaults[section] ?? .init(naturalHeight: 0)
            return (section, ReviewCardLayoutSolver.Measurement(
                naturalHeight: reviewMeasurementCache.value(for: key, level: .natural) ?? fallback.naturalHeight,
                intermediateHeight: reviewMeasurementCache.value(for: key, level: .intermediate) ?? fallback.intermediateHeight,
                compactHeight: reviewMeasurementCache.value(for: key, level: .compact) ?? fallback.compactHeight
            ))
        })
        return ReviewCardLayoutSolver.solve(.init(
            face: face,
            fields: fields,
            measurements: measurements,
            viewportHeight: availableHeight,
            minimumHeight: face == .front ? 0 : answerCardHeight,
            preset: renderProfile.preset(for: currentCard.card.reviewMode),
            columns: columns
        ))
    }

    private func reviewMeasurementKey(
        for currentCard: ReviewCardContent,
        face: ReviewCardFace,
        section: ReviewCardLayoutSolver.Section
    ) -> ReviewCardMeasurementKey {
        // While a link group is expanded the graph-links section is taller than its
        // compaction levels describe. Its heights go under their own key so they
        // never overwrite the collapsed natural/intermediate/compact measurements
        // (which collapsing returns to untouched) and never feed the solver a
        // height the collapsed card would not draw (#2043).
        let expandedVariant = section == .field(.graphLinks)
            ? linkExpansion.measurementVariant(cardKey: currentCardKey)
            : nil
        return ReviewCardMeasurementKey(
            cardKey: expandedVariant.map { currentCardKey + "|" + $0 } ?? currentCardKey,
            face: face,
            section: section,
            widthBucket: Int(containerWidth.rounded()),
            dynamicType: String(describing: dynamicTypeSize)
        )
    }

    private var currentCardKey: String {
        content.card.reviewCardKey
    }

    private func recordReviewSectionHeight(
        _ height: CGFloat,
        currentCard: ReviewCardContent,
        face: ReviewCardFace,
        section: ReviewCardLayoutSolver.Section,
        level: ReviewCardLayoutSolver.MeasurementLevel
    ) {
        guard height > 0 else { return }
        let key = reviewMeasurementKey(for: currentCard, face: face, section: section)
        reviewMeasurementCache.record(height, for: key, level: level)
    }

    @ViewBuilder
    private func reviewMeasurementProbes(
        _ field: ReviewCardField,
        currentCard: ReviewCardContent,
        face: ReviewCardFace
    ) -> some View {
        if shouldMountMeasurementProbes {
            let key = reviewMeasurementKey(for: currentCard, face: face, section: .field(field))
            let levels = reviewMeasurementCache.missingLevels(for: key)
            ZStack(alignment: .topLeading) {
                ForEach(levels, id: \.self) { level in
                    reviewOptionalField(
                        field,
                        currentCard: currentCard,
                        face: face,
                        policy: .measurementProbe(for: field, level: level)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onGeometryChange(for: ReviewCardSectionMeasurement.self) {
                        ReviewCardSectionMeasurement(height: $0.size.height, cardKey: currentCardKey)
                    } action: { measurement in
                        recordReviewSectionHeight(
                            measurement.height,
                            currentCard: currentCard,
                            face: face,
                            section: .field(field),
                            level: level
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reviewOptionalField(
        _ field: ReviewCardField,
        currentCard: ReviewCardContent,
        face: ReviewCardFace,
        policy: ReviewCardLayoutSolver.Policy
    ) -> some View {
        let card = currentCard.card
        switch field {
        case .partOfSpeech:
            if let partOfSpeech = card.partOfSpeech {
                Text(partOfSpeech)
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.tertiaryText)
            }
        case .difficultyTier:
            // Trailing-aligned, as the tier pill has always hugged the card's edge.
            if let tier = card.difficultyTier {
                VocabTierLabel(tier: tier)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .example:
            if let example = card.examples.first {
                CardRichTextRenderer.text(
                    example,
                    style: CardRichTextStyle(
                        font: appSkin.typography.example,
                        textColor: appSkin.palette.secondaryText,
                        highlightColor: appSkin.palette.highlightMark,
                        italic: true,
                        underlineHighlights: appSkin.highlight.showUnderline,
                        useBackgroundMark: appSkin.highlight.showBackground,
                        highlightWeight: appSkin.highlight.fontWeight,
                        backgroundOpacity: appSkin.highlight.backgroundOpacity,
                        underlineOpacity: appSkin.highlight.underlineOpacity
                    ),
                    mode: ReviewCardExampleRendering.mode(face: face, cardMode: card.reviewMode),
                    truncateAroundMarkedWordRadius: policy.exampleRadius
                        ?? ReviewCardLayoutSolver.naturalExampleRadius(
                            for: face,
                            staticRadius: appSkin.metrics.exampleTruncateRadius
                        ),
                    targetWord: card.word
                )
                .lineSpacing(appSkin.metrics.paragraphLineSpacing)
            }
        case .explanation:
            // One globally-limited rich text rather than per-paragraph clamps: the
            // solver budgets one section, so one clamp must own the whole block.
            // Natural is the shipped 3-line / 5pt compact meaning presentation.
            CardRichTextRenderer.text(
                ReviewCardExplanationContent.rawMarkdown(
                    from: currentCard.backDocument.meaningParagraphs()
                ),
                style: CardRichTextStyle(
                    font: appSkin.typography.body,
                    textColor: appSkin.palette.secondaryText,
                    highlightColor: appSkin.palette.highlightMark,
                    italic: false,
                    underlineHighlights: false,
                    useBackgroundMark: false,
                    highlightWeight: appSkin.highlight.fontWeight,
                    backgroundOpacity: appSkin.highlight.backgroundOpacity,
                    underlineOpacity: appSkin.highlight.underlineOpacity
                )
            )
            .lineSpacing(TodayReviewMetrics.foldMeaningLineSpacing)
            .lineLimit(ReviewCardLayoutSolver.explanationLineLimit(policyLineLimit: policy.lineLimit))
            .fixedSize(horizontal: false, vertical: true)
        case .collocations:
            let visible: [String] = if let limit = ReviewCardLayoutSolver.visibleCollocationLimit(
                lineLimit: policy.lineLimit
            ) {
                Array(card.collocations.prefix(limit))
            } else {
                card.collocations
            }
            VStack(alignment: .leading, spacing: appSkin.spacing.inlineGap) {
                CardDocumentCollocationsBlock(
                    items: visible,
                    compact: true,
                    maxRows: ReviewCardLayoutSolver.collocationRowLimit(lineLimit: policy.lineLimit),
                    explanations: collocationExplanations,
                    onExplain: actions.explainCollocation,
                    onView: actions.viewCollocationExplanation,
                    onDelete: actions.deleteCollocationExplanation
                )
                if policy.summarizesOverflow, card.collocations.count > visible.count {
                    Text("+\(card.collocations.count - visible.count)")
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                }
            }
        case .graphLinks:
            // No links yet → the add-link prompt, never nothing: this is the only
            // place the review card can start a link from.
            if currentCard.linkGroups.isEmpty {
                addLinkPrompt
            } else {
                reviewLinkStrip(currentCard.linkGroups, presentation: policy.graphLinkPresentation ?? .twoPerGroup)
            }
        }
    }

    // MARK: Fonts

    func reviewFrontWordFont(for text: String) -> Font {
        let count = text.count
        if count > 20 { return AppFonts.systemMono(size: TodayReviewMetrics.counterFontSizeCompact, weight: .semibold) }
        if count > 12 { return AppFonts.systemMono(size: TodayReviewMetrics.counterFontSizeMedium, weight: .semibold) }
        return AppFonts.systemMono(size: TodayReviewMetrics.counterFontSizeXLarge, weight: .semibold)
    }

    func reviewAnswerWordFont(for text: String) -> Font {
        let count = text.count
        if count > 20 { return appSkin.typography.translationTitle }
        if count > 12 { return AppFonts.systemMono(size: TodayReviewMetrics.counterFontSizeLarge, weight: .semibold) }
        return appSkin.typography.reviewWord
    }
}

// MARK: - Face Chrome

extension View {
    /// The only place a review card face pads its content. `ReviewCardChrome` hands
    /// the identical numbers to the solver as `chromeHeight`, so the budget and the
    /// drawn inset move together or not at all.
    func reviewCardFaceChrome(_ face: ReviewCardFace) -> some View {
        padding(ReviewCardChrome.padding)
            .padding(.top, ReviewCardChrome.extraTopInset(for: face))
    }
}
