import SwiftUI

private let flingSafetyNetTimeout: Duration = .milliseconds(800)

/// 方向標記只在 UITest 進程暴露進 a11y 樹（#2045）：id + 強度值供 UITest 斷言「放開後歸 0」；
/// 正式進程維持純裝飾（評分語意由下方按鈕承載，VoiceOver 不重複朗讀）。進程內不變 → 常數。
private let swipeMarkersExposedToUITest = AppRuntimeOptions.isUITesting()

// MARK: - Swipe Deck (resident card slots + swipe gesture)

extension TodayReviewPresenter {

    // MARK: Resident Slots（Phase 4 — 三 slot 結構常駐，值驅動）

    /// depth-2 殼層：純裝飾常駐節點，**恆駐 depth-2 不升頂**（Phase 4）——
    /// fling 期間 underPreview 從 depth-2 升走時，殼層原地補位，深度堆疊
    /// 視覺零空窗。只在 i+3 存在（remainingCount >= 3）時可見，暗示第四層；
    /// 可見性翻面瞬間被 depth-2 的 underPreview 卡遮蔽 —— 該卡半透明
    /// （idle layer opacity ≈ 0.44）且 rotation 與殼層不同，仍有微量透出，
    /// 為已知取捨（量級遠小於修掉的 depth-1 整卡 pop；殘餘 hitch 候選點）。
    /// 卡不足以 opacity 0 隱藏，不做 `if` 結構移除 —— settle 幀不付 insert/remove。
    func deckDepthShell(height: CGFloat) -> some View {
        let effectiveDepth: CGFloat = 2
        let scale: CGFloat = 1.0 - effectiveDepth * TodayReviewCardSlotLayout.stackDepthScaleStep
        let yOff: CGFloat = effectiveDepth * TodayReviewCardSlotLayout.stackDepthYStep
        let rotation = deckShellRotation
        let opacity = state.remainingCount >= 3 ? 0.35 : 0

        return AppRoundedRect(roundness: appSkin.roundness.card)
            .fill(appSkin.palette.cardBackground)
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.card)
                    .stroke(appSkin.palette.cardBorder.opacity(TodayReviewMetrics.cardBorderOpacity), lineWidth: 1)
            )
            .appElevation(.z1)
            .frame(height: height)
            .scaleEffect(scale)
            .offset(y: yOff)
            .rotationEffect(.degrees(rotation), anchor: .center)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 固定 identity 的卡 slot — 完整卡骨架（frontFoldSurface + chrome +
    /// answerFold stub）永久存活於全尺寸；姿態 = `f(role, dismissProgress)`
    /// 純值（TodayReviewCardSlotLayout.transform）。promote 時只有 role 翻面
    /// （hit-testing / a11y / 邊框值 diff），無結構 diff。
    // TODO(A/B 量測): 舊 cardStackLayers 對 deck 預覽包 .drawingGroup(opaque:false)。
    // slot 常駐後保守先移除（rasterize 互動卡會改變 gesture/a11y/fold 渲染行為）;
    // 若 device probe 顯示 preview 合成成本回升，A=對非 active 的那張卡包一層
    // .drawingGroup、B=維持移除，以 settle.frames/fling.frames 對比定案。
    @ViewBuilder
    func cardSlotView(slot: Int, viewport: ReviewCardViewport) -> some View {
        if slot < state.slots.count, let content = state.slots[slot].card {
            let role = state.slots[slot].assignment.role
            let isActive = role == .active
            let transform = TodayReviewCardSlotLayout.transform(
                role: role,
                swipeOffset: isActive ? swipeOffset : 0,
                dismissProgress: dismissProgress,
                stackRotation: slot < stackRotations.count ? stackRotations[slot] : 0,
                screenWidth: screenWidth,
                introProgress: introProgress
            )
            let borderOpacity = TodayReviewCardSlotLayout.borderOpacity(role: role, dismissProgress: dismissProgress)
            let slotShowsAnswer = isActive && state.revealStage.showsAnswer
            let slotHeight = deckSlotHeight(isActive: isActive)
            let _ = { if role == .preview, dismissProgress > 0 || dismissPhase != .idle {
                PerfLog.review.mark(
                    "stack.preview",
                    "w=\(content.card.word) scale=\(String(format: "%.3f", transform.scale)) op=\(String(format: "%.2f", transform.opacity)) prog=\(String(format: "%.2f", dismissProgress))"
                )
            } }()

            // 一張完整的卡（正面摺頁 ＋ chrome ＋ 背面摺頁 ＋ 摺疊動畫）＝
            // `ReviewCardView`；牌堆只負責姿態與互動鎖。互動鎖由這裡算好再傳，
            // 卡片內部不判 dismiss 相位。
            ReviewCardView(
                content: content,
                profile: notebookSettingsResolver.resolve(
                    notebookId: content.card.notebookId
                ).cardLayout,
                viewport: viewport,
                showsAnswer: slotShowsAnswer,
                // #2041：只有互動中的那張能處於暫時詳細；背後預覽恆依設定。
                temporarilyDetailed: isActive
                    && state.temporaryDetailCardKey == content.card.reviewCardKey,
                mountsBack: isActive && backContentMounted,
                interactive: isActive && isCardInteractive,
                borderOpacity: borderOpacity,
                collocationExplanations: collocationExplanations,
                notebookBadge: notebookBadges[content.card.notebookId],
                actions: ReviewCardActions(
                    advanceReveal: onAdvanceReveal,
                    collapseReveal: onCollapseReveal,
                    detailTap: onDetailTap,
                    linkTap: onLinkTap,
                    addLink: onAddLink,
                    explainCollocation: onExplainCollocation,
                    viewCollocationExplanation: onViewCollocationExplanation,
                    deleteCollocationExplanation: onDeleteCollocationExplanation,
                    toggleTemporaryDetail: onToggleTemporaryDetail,
                    toggleLinkGroup: onToggleLinkGroup
                ),
                linkExpansion: state.linkExpansion,
                // FIX(review-flip-gap)：逐 slot 記實測 front 高度（active slot
                // 恆 uncap → 量到自然高度）。`activeCardHeight` 讀 active slot 的值，
                // 供非 active slot cap（見下方的 .frame）。量測只有卡片自己做得到，
                // 所以由它回吐；deck 這邊不再重覆量一次。
                onFrontHeightChange: { h in
                    // 比對 slot 自己上次記的值（不是卡片量測快取）：slot 回收成別張卡後
                    // 存的是舊卡高度，必須被新量測覆寫（#2026 第三種跳法）。
                    guard slotFrontHeights.indices.contains(slot),
                          let updated = TodayReviewDeckHeight.slotHeightUpdate(
                              stored: slotFrontHeights[slot], measured: h
                          ) else { return }
                    slotFrontHeights[slot] = updated
                }
            )
            // FIX(review-flip-gap)：非 active slot 的 layout 高度 cap 到 active 卡
            // 高度，讓 ZStack(alignment:.top) 只由 active 卡決定高度、不被較高的背景
            // 卡撐大。active slot 穩態傳 nil（自然高度，反而定義 activeCardHeight）。
            // #2026：role 翻面 / 高度過渡期間 active 改釘成過渡值（`deckShellHeight`，
            // spring 驅動），nil ↔ 固定值的硬切因此只發生在「兩者相等」的瞬間。
            // 規則（含「為何這樣取」）與單元測試見 TodayReviewDeckHeight。
            .frame(height: slotHeight, alignment: .top)
            // 內容溢出收斂：多數較高背景卡（如 production 長例句）會被 ReviewFoldSurface
            // 內部 .clipShape + cap frame 自然截斷、不溢出；但 fixedSize 內容（多行
            // recognition 長單字）會堅持自然高度而溢出 frame 往下渲染。統一 clip 掉
            // 非 active slot 超出 cap 的部分。active slot 給超大負 inset = 不裁切，
            // 保留卡片陰影（appElevation）。value-conditional 單一 modifier → 不破壞
            // Phase 4 常駐 slot 身分。
            // #2026：active 被釘高（過渡中）時只裁底邊 —— 變高時新卡自然高度 > 釘高，
            // 內容會越過 frame 底邊蓋住「點一下展開」區（規則見 TodayReviewDeckHeight.clipBleed）。
            .clipShape(DeckSlotClipShape(
                bleed: TodayReviewDeckHeight.clipBleed(isActive: isActive, pinned: slotHeight != nil)
            ))
            .geometryGroup()
            // #2026 r7：展開中 active 的自然高度（＝背面總高）變動時追蹤進 latch，非 active cap 跟上，
            // 背面縮短不留 H-H' 縫。只量 active：展開時其 slotHeight 為 nil → 量到的是自然高度，不受 cap 回授。
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                guard isActive else { return }
                trackRevealedBackHeight(h)
            }
            #if DEBUG
            // gap 調查（slot 整體）：量整個 slot VStack 的 layout 高度（transform 前）。
            // 非 active slot 的 h 明顯 > active = 撐高 reviewCard ZStack、把 expand
            // zone 下推 → 使用者看到的縫隙。role/word 指認撐高者。目前只 emit kind=slot；
            // answer 高度未量測，H1/H2 的 answer 分量尚未接線。
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                logSlotGeometry(slot: slot, role: role, kind: "slot", word: content.card.word, height: h)
            }
            #endif
            .animation((dismissPhase == .idle && !suppressFoldAnimation) ? AppMotionResolver.animation(.reveal, reduceMotion: reduceMotion) : nil,
                       value: slotShowsAnswer)
            // #2045 方向標記：常駐 overlay（不改 slot 結構與 layout 高度），只有 active
            // 吃 swipeOffset，其餘 slot 恆 0。放在姿態 modifier 之前 → 跟著卡片位移與旋轉。
            .overlay(alignment: .top) {
                swipeMarkers(swipeOffset: isActive ? swipeOffset : 0)
            }
            // 姿態 = 純值 diff（modifier 結構固定）。順序對齊舊雙軌：
            // scale → offset → rotation → opacity；rotation anchor 在 role 翻面
            // 時切換（active=.bottom / preview=.center），翻面瞬間角度恆 0，無跳動。
            .scaleEffect(transform.scale)
            .offset(x: transform.xOffset, y: transform.yOffset)
            .rotationEffect(.degrees(transform.rotationDegrees), anchor: isActive ? .bottom : .center)
            .opacity(transform.opacity)
            // zIndex 按 role 排深度（殼層預設 0 恆最底）。三 slot 制下不可用
            // 宣告順序當 tie-breaker：slot index 與深度的對應每次推進都在輪替。
            .zIndex(role == .active ? 3 : (role == .preview ? 2 : 1))
            // promote 的本體：hit-testing gate 翻面（preview 純裝飾不可點）。
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .simultaneousGesture(swipeDragGesture)
        }
    }

    #if DEBUG
    /// Gap 調查儀器（DEBUG-only，RELEASE 零成本）。逐 slot 記 layout 高度，
    /// 供離線比對「非 active slot 是否比 active 高 → 撐高 reviewCard ZStack →
    /// 把 expand zone 下推 = 卡片與底部大縫隙」。
    /// - kind=slot：整個 slot VStack 的 layout 高度（本檔 emit）。
    /// - kind=deck：牌組層級的高度，slot=-1（TodayReviewPresenter emit）。
    /// 目前只 emit slot 與 deck；kind=answer 未 emit，answer surface 高度未量測。
    /// 不 gate、附完整相位脈絡（reveal/dismiss/off/idx），離線 grep 過濾 settled front。
    func logSlotGeometry(slot: Int, role: TodayReviewCardSlotRole, kind: String, word: String, height: CGFloat) {
        PerfLog.review.mark(
            "gap.geom",
            "slot=\(slot) role=\(role) kind=\(kind) w=\(word) h=\(String(format: "%.1f", height)) reveal=\(state.revealStage.rawValue) dismiss=\(dismissPhase == .idle ? 0 : 1) off=\(Int(swipeOffset)) idx=\(state.progressText)"
        )
    }
    #endif

    /// 「記得 / 忘記」方向標記（#2045）。兩個標記常駐、不透明度連續由 swipeOffset 推導
    /// （`TodayReviewFling.markerOpacity`），無 if/else 結構切換：拖動漸入、回彈沿 snap-back
    /// spring 淡出、fling（swipe 或按鈕）沿同一條 fling spring 漸入、settle no-anim 同幀歸 0。
    /// 純裝飾：不吃命中；正式進程不進 a11y，UITest 進程以 id + 強度值暴露
    /// （`TodayReviewSwipeMarkerKind`，值 = 當下不透明度，`%.2f`）。
    func swipeMarkers(swipeOffset: CGFloat) -> some View {
        let threshold = TodayReviewMetrics.swipeThreshold
        let remembered = TodayReviewFling.markerOpacity(swipeOffset: swipeOffset, threshold: threshold, direction: 1)
        let forgot = TodayReviewFling.markerOpacity(swipeOffset: swipeOffset, threshold: threshold, direction: -1)
        return HStack(alignment: .top, spacing: 0) {
            swipeMarker(
                title: L10n.string("記得"),
                tint: appSkin.palette.success,
                tilt: -TodayReviewMetrics.swipeMarkerTilt
            )
            .opacity(remembered)
            .accessibilityIdentifier(TodayReviewSwipeMarkerKind.remembered.accessibilityID)
            .accessibilityValue(TodayReviewSwipeMarkerKind.accessibilityValue(opacity: remembered))
            Spacer(minLength: 0)
            swipeMarker(
                title: L10n.string("忘記"),
                tint: appSkin.palette.destructive,
                tilt: TodayReviewMetrics.swipeMarkerTilt
            )
            .opacity(forgot)
            .accessibilityIdentifier(TodayReviewSwipeMarkerKind.forgot.accessibilityID)
            .accessibilityValue(TodayReviewSwipeMarkerKind.accessibilityValue(opacity: forgot))
        }
        .padding(TodayReviewMetrics.swipeMarkerInset)
        .background { swipeMarkerPeakProbes() }
        .allowsHitTesting(false)
        .accessibilityHidden(!swipeMarkersExposedToUITest)
    }

    /// 累計手勢峰值（見 `TodayReviewSwipeMarkerPeak`）。非 UITest 進程直接返回，不增加 body 失效。
    private func recordSwipeMarkerPeak(to newOffset: CGFloat) {
        guard swipeMarkersExposedToUITest else { return }
        let next = swipeMarkerPeak.recording(
            from: swipeOffset,
            to: newOffset,
            threshold: TodayReviewMetrics.swipeThreshold
        )
        if next != swipeMarkerPeak { swipeMarkerPeak = next }
    }

    /// UITest-only 峰值探針：1pt 透明元素，id + 值（`%.2f`）。以 background 掛在標記 HStack 上，
    /// 不影響 layout；因峰值住在 presenter（不隨 slot 輪替），卡片飛出推進後仍可讀。
    @ViewBuilder
    private func swipeMarkerPeakProbes() -> some View {
        if swipeMarkersExposedToUITest {
            VStack(spacing: 0) {
                ForEach(TodayReviewSwipeMarkerKind.allCases, id: \.self) { kind in
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier(kind.peakAccessibilityID)
                        .accessibilityValue(TodayReviewSwipeMarkerKind.accessibilityValue(opacity: swipeMarkerPeak.value(for: kind)))
                }
            }
        }
    }

    private func swipeMarker(title: String, tint: Color, tilt: Double) -> some View {
        Text(title)
            .font(appSkin.typography.sectionTitle)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.s3)
            .padding(.vertical, AppSpacing.s1)
            .background(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .fill(appSkin.palette.cardBackground.opacity(TodayReviewMetrics.swipeMarkerFillOpacity))
            )
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .stroke(tint, lineWidth: TodayReviewMetrics.swipeMarkerBorderWidth)
            )
            .rotationEffect(.degrees(tilt))
    }

    // MARK: Settle seam（fling 完成時刻的 role 輪替）

    /// fling 完成、**在 no-anim transaction 內**把牌堆推進一格。
    /// 共用 settle 縫 —— #2026（卡片區高度過渡）與 #2027（progress / 按鈕回饋）
    /// 都只能改這裡的「單一職責步驟」，不得在 `completeFling` 內另開分支：
    ///
    /// 1. `releaseSwipePose`：swipeOffset 歸零、輪替被回收 slot 的隨機旋轉。凍結的
    ///    toolbar intensity **不在此歸零**（#2027）：由 `completeFling` 下一個 runloop
    ///    以 spring 放鬆，否則 no-anim transaction 會讓按鈕放大 / 發光硬切回原狀。
    /// 2. `gateBackContent`：背面樹放閘（必須在推進「前」）。
    /// 3. `pinDeckHeight`：把卡片區高度釘在畫面上當下的 layout 高度 —— 新 active
    ///    當幀取舊高度（零跳變），隨後由 `.onChange(of: deckHeightKey)` 觸發 spring
    ///    過渡到新卡高度。高度過渡**不**走 dismissProgress（見 #2026）。
    /// 4. `advance`：`callback()` 推進 currentIndex，role 三向輪替，隨後 dismissPhase=idle。
    ///
    /// 呼叫端負責包 `disablesAnimations` 的 Transaction 與 settle 後的 suppress.reset。
    func settleDeckAfterFling(callback: () -> Void) {
        releaseSwipePose()
        gateBackContent()
        pinDeckHeight()
        // promote（Phase 4）：callback() 推進 currentIndex → slot role
        // 在本 no-anim transaction 內三向輪替。preview→active 與
        // underPreview→preview 兩個存活 slot 的 transform 已被 fling
        // 動畫推到目標值、內容 index 不變 → settle 幀零內容 diff；
        // 唯一內容 diff 落在被回收、沉到 depth-2 的舊 active slot
        // （被殼層位置遮蔽）。模型推進時序與舊雙軌完全相同
        // （submit 仍在 fling 完成時刻，非樂觀預推）。
        callback()
        dismissPhase = .idle
    }

    private func releaseSwipePose() {
        swipeOffset = 0
        // 只重隨機被回收的舊 active slot（settle 後換內容、沉到
        // depth-2）—— 存活的 preview/underPreview slot rotation 持久，
        // 角色輪替跨 settle 連續不跳動。
        if let recycled = state.slots.firstIndex(where: { $0.assignment.role == .active }),
           recycled < stackRotations.count {
            stackRotations[recycled] = .random(in: -1...1)
        }
    }

    /// 幽靈背面樹（device trace 證據：settle burst 內
    /// CardDocumentExampleBlock/CardRichTextRenderer 樣本）：
    /// 從背面送出時 backContentMounted 仍 true，callback() 推進
    /// currentIndex 後 settle 幀會替「新卡」完整建出背面樹，下一幀
    /// 又被 onChange(currentCardKey) 放閘拆毀——同幀建、次幀拆的
    /// 純白工。閘必須在推進「前」放下；onChange 仍在（冪等，收
    /// previous/shuffle 等其他推進路徑）。
    private func gateBackContent() {
        backMountGeneration += 1
        backContentMounted = false
        suppressFoldAnimation = true
    }

    /// 起點 = 畫面上當下的卡片區 layout 高度（含背面展開後的總高；動畫尚未收尾時
    /// 也是畫面當下值）。`layoutHeight == 0`（尚未 layout）時不動，退回啟動規則。
    private func pinDeckHeight() {
        let height = deckHeightProbe.layoutHeight
        guard height > 0 else { return }
        deckHeightGeneration += 1
        deckHeightInFlight = false
        deckShellHeight = height
    }

    // MARK: Swipe Gesture + Fling Animation

    var screenWidth: CGFloat { containerWidth }

    /// 甩出進度 (0=靜止, 1=完全離開) — 驅動牌堆同步升頂（規則見 TodayReviewFling）
    var dismissProgress: CGFloat {
        TodayReviewFling.dismissProgress(swipeOffset: swipeOffset)
    }

    var swipeEnabled: Bool {
        dismissPhase == .idle && !state.isAutoPlaying
    }

    var swipeDragGesture: some Gesture {
        DragGesture(minimumDistance: 15, coordinateSpace: .local)
            .onChanged { value in
                guard swipeEnabled else {
                    hintAutoplayBlockedSwipe(translation: value.translation)
                    return
                }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                recordSwipeMarkerPeak(to: value.translation.width)
                withAnimation(AppMotionResolver.animation(.tracking, reduceMotion: reduceMotion)) {
                    swipeOffset = value.translation.width
                }
            }
            .onEnded { value in
                if autoplayBlockedHintShown { autoplayBlockedHintShown = false }
                guard swipeEnabled else { return }
                let threshold = TodayReviewMetrics.swipeThreshold
                if value.translation.width < -threshold {
                    flingCard(direction: -1, velocity: abs(value.velocity.width), callback: onForgot)
                } else if value.translation.width > threshold {
                    flingCard(direction: 1, velocity: abs(value.velocity.width), callback: onRemembered)
                } else {
                    withAnimation(AppMotionResolver.animation(.snapBack, reduceMotion: reduceMotion)) {
                        swipeOffset = 0
                    }
                }
            }
    }

    /// 自動播放中水平滑動被 `swipeEnabled` 擋下時說出原因（#2046）：每次手勢一次、
    /// 水平主導才算（垂直捲動不提示）。被擋時 `swipeOffset` 從不寫入，卡片不會位移；
    /// 事件鍵與按鈕 / 鍵盤入口共用，連續操作取代而非堆疊。
    private func hintAutoplayBlockedSwipe(translation: CGSize) {
        guard state.isAutoPlaying,
              !autoplayBlockedHintShown,
              abs(translation.width) > abs(translation.height) else { return }
        autoplayBlockedHintShown = true
        toastCoordinator.warning(
            L10n.string("todayReview.autoplay.blockedHint"),
            key: TodayReviewState.autoplayBlockedNoticeKey
        )
    }

    /// 按鈕 / 鍵盤評分入口（#3127）：與滑動放手走同一條甩出（同一 plan、同一回饋、同一 settle）。
    /// 甩出中到達的評分依序暫存（有界 FIFO），每次 settle 套用一筆：不覆蓋先到者，也不在甩出中同步 submit。
    func gradeFromControl(remember: Bool, source: String) {
        guard dismissPhase == .idle else {
            bufferedGrade.receive(remember: remember)
            return
        }
        flingCard(
            direction: remember ? 1 : -1,
            source: source,
            callback: remember ? onRemembered : onForgot
        )
    }

    /// settle 後套用甩出中暫存的評分：每次 settle 只取最早一筆（FIFO，#3278），
    /// 下一筆由該次甩出的 settle 再取出。自動播放中或已無卡片時整批丟棄。
    func applyBufferedGrade() {
        guard let remember = bufferedGrade.takeAtSettle() else { return }
        guard swipeEnabled, state.currentCard != nil else {
            bufferedGrade.discardAll()
            return
        }
        gradeFromControl(remember: remember, source: "buffered")
    }

    /// 統一的甩出動畫 — swipe 放手、按鈕、ReviewProbe 共用**同一條過渡**（#2027）：
    /// 終點 / 凍結 intensity / spring 時長全由 `TodayReviewFling.plan` 算出，
    /// 入口之間只差起點 offset 與手指速度（按鈕 / probe 為 nil → 名目速度）。
    func flingCard(direction: CGFloat, velocity: CGFloat? = nil, source: String = "swipe", callback: @escaping () -> Void) {
        guard dismissPhase == .idle else { return }
        let plan = TodayReviewFling.plan(
            direction: direction,
            startOffset: swipeOffset,
            releaseVelocity: velocity,
            screenWidth: screenWidth,
            threshold: TodayReviewMetrics.swipeThreshold,
            baseDuration: Double(DesignTokens.Motion.Spring.SwipeFling.response)
        )
        recordSwipeMarkerPeak(to: plan.targetOffset)
        dismissPhase = .animatingOut
        frozenSwipeIntensity = plan.frozenIntensity
        if direction > 0 { flingRememberedTrigger += 1 } else { flingForgotTrigger += 1 }
        let _flingStart = DispatchTime.now()
        let velocityText = velocity.map { "\(Int($0))" } ?? "nil"
        PerfLog.review.mark(
            "fling.start",
            "source=\(source) dir=\(direction) vel=\(velocityText) start=\(Int(swipeOffset)) target=\(Int(plan.targetOffset)) dur=\(String(format: "%.3f", plan.duration))"
        )
        // Record the real per-frame cadence across the fly-off window. Distinguishes
        // "animation ran smoothly to completion" from "main thread idle, advance gated
        // by the 0.8s safety net" — body-eval marks can't see this (CA interpolates the
        // offset at the render layer without re-running the body each frame).
        PerfLog.review.startFrameSampler("fling.frames")
        // Second sampler over a WIDER window: fling.frames stops at fling.complete
        // (~200ms) and so cannot see the post-landing reinit storm (the detached DB
        // save → @Query invalidation → cover-closure re-run lands async, AFTER the
        // fling). settle.frames runs the full 800ms (stopped in the safety Task) to
        // capture whether that storm actually drops frames — the link the earlier
        // measurement window structurally missed.
        PerfLog.review.startFrameSampler("settle.frames")

        // Completion block — shared between animation callback and safety fallback.
        // `caller` tags WHICH path fired it: `animation` = withAnimation completion
        // fired (and anim_dur ≈ how long .logicallyComplete took for the spring);
        // `safetyNet` = the 0.8s fallback fired because completion never did. Decisive
        // discriminator for the flip→next-card pause root cause.
        let completeFling: @MainActor @Sendable (String) -> Void = { [self] caller in
            guard dismissPhase == .animatingOut else {
                PerfLog.review.mark("fling.complete.skip", "caller=\(caller) at=\(PerfChannel.ms(since: _flingStart))ms (already idle)")
                return
            }
            PerfLog.review.stopFrameSampler("fling.frames")
            var noAnim = Transaction(animation: nil)
            noAnim.disablesAnimations = true
            PerfLog.review.mark("fling.complete", "caller=\(caller) anim_dur=\(PerfChannel.ms(since: _flingStart))ms (fling.start->complete)")
            TodayReviewState.flingClock = .now()
            PerfLog.review.measure("fling.transaction") {
                withTransaction(noAnim) {
                    settleDeckAfterFling(callback: callback)
                }
            }
            DispatchQueue.main.async {
                suppressFoldAnimation = false
                PerfLog.review.mark("suppress.reset", "at=\(PerfChannel.ms(since: _flingStart))ms (fling.start->suppressOff)")
                // toolbar 回饋放鬆（#2027）：凍結值撐過 settle 幀後才以 spring 歸零；
                // 期間 swipeIntensity 讀凍結值（TodayReviewFling.toolbarIntensity）。
                // 守門：下一次 fling 若已開始，不覆寫它的凍結值。
                if dismissPhase == .idle {
                    withAnimation(AppMotionResolver.animation(.snapBack, reduceMotion: reduceMotion)) {
                        frozenSwipeIntensity = 0
                    }
                }
                applyBufferedGrade()
            }
        }

        withAnimation(AppMotionResolver.animation(.fling(duration: plan.duration), reduceMotion: reduceMotion), completionCriteria: .logicallyComplete) {
            swipeOffset = plan.targetOffset
        } completion: {
            completeFling("animation")
        }

        // Safety fallback: if animation completion never fires (macOS edge case),
        // force-complete after a generous timeout to prevent UI deadlock.
        Task { @MainActor in
            try? await Task.sleep(for: flingSafetyNetTimeout)
            completeFling("safetyNet")
            // Always close the wide window here (the safety Task runs regardless of
            // whether completeFling skipped) → 800ms frame trace spanning fling +
            // reinit storm.
            PerfLog.review.stopFrameSampler("settle.frames")
        }
    }
}

// MARK: - Slot clip（#2026）

/// slot 的裁切形狀：`side` 外擴上/左/右、`bottom` 外擴底邊。外擴量為值參數，
/// modifier 結構固定（不破壞 Phase 4 常駐 slot 身分）；量變只在 role / 過渡邊界發生。
struct DeckSlotClipShape: Shape {
    let bleed: TodayReviewDeckHeight.ClipBleed

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX - bleed.side,
            y: rect.minY - bleed.side,
            width: rect.width + 2 * bleed.side,
            height: rect.height + bleed.side + bleed.bottom
        ))
    }
}
