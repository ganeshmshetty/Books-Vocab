import Foundation

/// 複習卡知識連結區每一組的列內容（#2043）。純值：「顯示哪幾個、+N 是多少、
/// 能不能展開」只由這裡算，畫面與測試讀同一份。
enum ReviewCardLinkStripLayout {
    /// 展開區最多就地列出幾個連結。展開不得把卡片撐出畫面，所以高度要有上限；
    /// 超過的部分留在「+K」計數裡（同組實務上遠小於此）。
    static let expandedLimit = 20

    struct Row: Equatable {
        /// 與組名同列的連結（收合時依 solver 的 presentation 取前 2／1／0 個）。
        let leading: [KGCardLinkSummary]
        /// 展開時就地追加在下方的其餘連結（至多 `expandedLimit` 個）；收合時為空。
        let expanded: [KGCardLinkSummary]
        /// 「+N」的 N。收合時＝所有看不到的連結；展開後只剩超過 `expandedLimit`
        /// 與裝置上沒有的連結（group.overflowCount）。
        let overflowCount: Int
        /// 有被藏起來、且裝置上真的有的連結 → 「+N」是按鈕；否則只是計數文字。
        let isExpandable: Bool

        /// 畫面上依序出現的連結。收合與展開共用同一條流式佈局，兩者的差別只在這個清單
        /// 是否多出 `expanded`（#3114）。
        var visible: [KGCardLinkSummary] { leading + expanded }
    }

    static func row(
        for group: ReviewCardLinkGroup,
        presentation: ReviewCardLayoutSolver.GraphLinkPresentation,
        isExpanded: Bool
    ) -> Row {
        let presentationLimit: Int = switch presentation {
        case .twoPerGroup: 2
        case .onePerGroup: 1
        case .summary: 0
        }
        // A link being created must be visible the moment the user starts it
        // (#2133): whatever the presentation cut is, every pending item stays beside
        // the label and only real links fall into "+N". Pending items lead the group
        // even if the caller did not order them first.
        let pending = group.items.filter(\.isPendingCreation)
        let ordered = pending + group.items.filter { !$0.isPendingCreation }
        let limit = max(presentationLimit, pending.count)
        let leading = Array(ordered.prefix(limit))
        let hidden = Array(ordered.dropFirst(limit))
        let unavailable = max(group.overflowCount, 0)
        let shownWhenExpanded = Array(hidden.prefix(expandedLimit))
        return Row(
            leading: leading,
            expanded: isExpanded ? shownWhenExpanded : [],
            overflowCount: unavailable + (isExpanded ? hidden.count - shownWhenExpanded.count : hidden.count),
            isExpandable: !hidden.isEmpty
        )
    }
}

/// 哪幾組連結被展開（#2043）。只存在記憶體，由 `TodayReviewState` 持有（#3130）並於每次換卡清空；
/// 綁定一張卡：舊卡的展開狀態對新卡永遠讀不到。
struct ReviewCardLinkExpansion: Equatable {
    private(set) var cardKey: String?
    private(set) var groupIDs: Set<String> = []

    func isExpanded(_ groupID: String, cardKey: String) -> Bool {
        self.cardKey == cardKey && groupIDs.contains(groupID)
    }

    /// 換卡即還原（#3130）：清空展開，與 temporary detail 同一生命週期。回傳是否真的有變化，
    /// 閒置時不寫入（與 `ReviewCardTemporaryDetail.reset()` 同慣例）。
    @discardableResult
    mutating func reset() -> Bool {
        guard cardKey != nil || !groupIDs.isEmpty else { return false }
        self = ReviewCardLinkExpansion()
        return true
    }

    mutating func toggle(_ groupID: String, cardKey: String) {
        if self.cardKey != cardKey {
            self.cardKey = cardKey
            groupIDs = []
        }
        if groupIDs.contains(groupID) {
            groupIDs.remove(groupID)
        } else {
            groupIDs.insert(groupID)
        }
    }

    /// Measurement-key suffix for the graph-links section while any group of this
    /// card is expanded. Expanded heights live under their own key so collapsing
    /// returns to the untouched collapsed measurements instead of leaving
    /// expanded heights behind in the compaction levels the card is not drawing.
    func measurementVariant(cardKey: String) -> String? {
        guard self.cardKey == cardKey, !groupIDs.isEmpty else { return nil }
        return "links-expanded:" + groupIDs.sorted().joined(separator: ",")
    }
}
