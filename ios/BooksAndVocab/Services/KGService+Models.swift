//
//  KGService+Models.swift
//  Books & Vocab
//
//  Wire models for KG API responses / requests.
//

import Foundation

/// KG server health response
struct KGHealthResponse: Codable {
    let status: String
    let cards: Int
    let links: Int
    let pendingCandidates: Int
    let lastModified: String?
}

/// health 探活回應映射到 KGService 可觀測狀態的純結果。
///
/// 刻意**不含**任何時間欄位：`lastModified` 是「後端資料最後被寫入的時間」，
/// 與 `lastSyncDate`（裝置最後一次成功同步的時間，由 `backgroundSync` 設定）語意不同。
/// 過去 healthCheck 把 `lastModified` 寫進 `lastSyncDate`，導致「純 pull、未寫入」的
/// 同步後，timer 觸發 health 就把同步時間倒退回後端上次寫入時刻（顯示「N 小時前」）。
struct HealthSnapshot: Equatable {
    let isConnected: Bool
    let serverCardCount: Int
}

extension KGHealthResponse {
    var snapshot: HealthSnapshot {
        HealthSnapshot(isConnected: status == "ok", serverCardCount: cards)
    }
}

/// Vocab add response
struct KGAddResponse: Codable {
    let created: Int
    let skipped: Int
    let duplicates: [String]
    let cardIds: [String: String]
    /// 後端 per-item 拒收（#2248）；其他項目照常寫入。舊回應缺欄位時為空陣列。
    let rejected: [KGRejectedItem]

    init(
        created: Int,
        skipped: Int,
        duplicates: [String],
        cardIds: [String: String],
        rejected: [KGRejectedItem] = []
    ) {
        self.created = created
        self.skipped = skipped
        self.duplicates = duplicates
        self.cardIds = cardIds
        self.rejected = rejected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decode(Int.self, forKey: .created)
        skipped = try container.decode(Int.self, forKey: .skipped)
        duplicates = try container.decode([String].self, forKey: .duplicates)
        cardIds = try container.decode([String: String].self, forKey: .cardIds)
        rejected = try container.decodeIfPresent([KGRejectedItem].self, forKey: .rejected) ?? []
    }
}

/// 後端 `RejectedVocabItem`：`index` 為原始提交陣列位置；`word` 可能缺失。
struct KGRejectedItem: Codable, Equatable {
    let index: Int
    let word: String?
    let reason: String
}

struct KGTranslationConfig: Codable {
    let source_lang: String?
    let target_lang: String?
    /// 單一 group LWW 時戳（epoch 秒）。source/target 共用（設計 A），對齊
    /// KGVocabUIConfig / KGReviewModeConfig。nil = 從未寫過（向後相容舊回應）。
    let updated_at: Double?
}

/// Per-user 全局複習時鐘暫停態(對應後端 ReviewClockConfig)。is_paused + paused_at
/// 複合,共用 updated_at 驅動跨裝置 LWW。
struct KGReviewClockConfig: Codable {
    let is_paused: Bool
    let paused_at: String?
    let updated_at: Double?
}

/// Per-user 複習模式 + 自訂 SRS 參數(對應後端 ReviewModeConfig)。
/// mode + 5 個 custom_*
/// 複合,共用 updated_at 驅動跨裝置 LWW。欄位名為後端 snake_case(wire format),
/// 與 iOS store 的 camelCase customParams 之間由 SettingsCoordinator 的 push/cold-start mapper 轉換。
struct KGReviewModeConfig: Codable {
    let mode: String
    let custom_initial_interval_hours: Double
    let custom_remembered_multiplier: Double
    let custom_forgot_multiplier: Double
    let custom_minimum_interval_hours: Double
    let custom_maximum_interval_hours: Double
    let updated_at: Double?

    private enum CodingKeys: String, CodingKey {
        case mode
        case custom_initial_interval_hours
        case custom_remembered_multiplier
        case custom_forgot_multiplier
        case custom_minimum_interval_hours
        case custom_maximum_interval_hours
        case updated_at
    }

    init(
        mode: String,
        custom_initial_interval_hours: Double,
        custom_remembered_multiplier: Double,
        custom_forgot_multiplier: Double,
        custom_minimum_interval_hours: Double,
        custom_maximum_interval_hours: Double,
        updated_at: Double?
    ) {
        self.mode = mode
        self.custom_initial_interval_hours = custom_initial_interval_hours
        self.custom_remembered_multiplier = custom_remembered_multiplier
        self.custom_forgot_multiplier = custom_forgot_multiplier
        self.custom_minimum_interval_hours = custom_minimum_interval_hours
        self.custom_maximum_interval_hours = custom_maximum_interval_hours
        self.updated_at = updated_at
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(String.self, forKey: .mode)
        custom_initial_interval_hours = try values.decode(Double.self, forKey: .custom_initial_interval_hours)
        custom_remembered_multiplier = try values.decode(Double.self, forKey: .custom_remembered_multiplier)
        custom_forgot_multiplier = try values.decode(Double.self, forKey: .custom_forgot_multiplier)
        custom_minimum_interval_hours = try values.decode(Double.self, forKey: .custom_minimum_interval_hours)
        custom_maximum_interval_hours = try values.decode(Double.self, forKey: .custom_maximum_interval_hours)
        updated_at = try values.decodeIfPresent(Double.self, forKey: .updated_at)
    }
}

/// Per-user vocab UI 跨裝置偏好(對應後端 VocabUIConfig 的 vocab_ui group)。目前僅
/// active_notebook_id(全域 active notebook 游標)+ updated_at LWW;欄位名為後端 snake_case
/// wire format,iOS store 用同名 key,故無需 mapper(不像 review_mode 的 camelCase customParams)。
struct KGVocabUIConfig: Codable {
    let active_notebook_id: String
    let updated_at: Double?
}

/// Per-user 自動連結開關(對應後端 AutoLinkConfig 的 auto_link group)。enabled 控制
/// backend judge pipeline 是否自動建立知識圖譜連結;關閉時新單字仍照常 enrich+embed
/// 並排入待判集合,重新開啟後續判。updated_at(epoch 秒)驅動跨裝置 LWW。
struct KGAutoLinkConfig: Codable {
    let enabled: Bool
    let updated_at: Double?
}

/// User config request/response
struct KGUserConfig: Codable {
    let translation: KGTranslationConfig?
    let review_clock: KGReviewClockConfig?
    let review_mode: KGReviewModeConfig?
    let vocab_ui: KGVocabUIConfig?
    let auto_link: KGAutoLinkConfig?
}
