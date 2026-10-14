//
//  NotebookSortOption.swift
//  Books & Vocab
//
//  單字本書架排序選項 — 預設 manual（sortOrder asc）

import Foundation
import SwiftData

enum NotebookSortOption: String, CaseIterable, Identifiable {
    case manual          // 手動排序（沿用 sortOrder，含 isDefault 優先）
    case nameAsc         // 名稱 A→Z
    case nameDesc        // 名稱 Z→A
    case createdNewest   // 建立時間 新→舊
    case createdOldest   // 建立時間 舊→新
    case updatedNewest   // 最後更新 新→舊
    case cardCountDesc   // 卡片數 多→少
    case dueCountDesc    // 待複習 多→少
    case lastActivity    // 最近活動 新→舊

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual:        return L10n.string("手動排序")
        case .nameAsc:       return L10n.string("名稱 A→Z")
        case .nameDesc:      return L10n.string("名稱 Z→A")
        case .createdNewest: return L10n.string("最新建立")
        case .createdOldest: return L10n.string("最早建立")
        case .updatedNewest: return L10n.string("最近更新")
        case .cardCountDesc: return L10n.string("卡片最多")
        case .dueCountDesc:  return L10n.string("待複習最多")
        case .lastActivity:  return L10n.string("最近活動")
        }
    }

    var systemImage: String {
        switch self {
        case .manual:        return "hand.draw"
        case .nameAsc:       return "textformat.abc"
        case .nameDesc:      return "textformat.abc.dottedunderline"
        case .createdNewest: return "calendar.badge.plus"
        case .createdOldest: return "calendar"
        case .updatedNewest: return "clock.arrow.circlepath"
        case .cardCountDesc: return "rectangle.stack.fill"
        case .dueCountDesc:  return "bell.badge"
        case .lastActivity:  return "sparkles"
        }
    }

    /// UserDefaults persistence key
    static let storageKey = "notebookSortOption"

    static func load() -> NotebookSortOption {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = NotebookSortOption(rawValue: raw) else {
            return .manual
        }
        return value
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

extension NotebookSortOption {
    /// `@Query` 的手動排序次序，與 `.manual` 的 comparator 一致（sortOrder → createdAt → remoteId）。
    /// 計算屬性而非 stored static：`Notebook` 非 Sendable，避免 Swift 6 global-state 檢查。
    static var manualOrderDescriptors: [SortDescriptor<Notebook>] {
        [
            SortDescriptor(\Notebook.sortOrder),
            SortDescriptor(\Notebook.createdAt),
            SortDescriptor(\Notebook.remoteId),
        ]
    }
}

extension NotebookSortOption {
    /// 依排序選項對 notebooks 排序。預設 notebook (`isDefault == true`) 永遠放最前面。
    /// 需要 caller 提供 `NotebookStatsCalculator.compute(...)` 算好的 stats（避免重算 O(n)）。
    func sort(
        _ notebooks: [Notebook],
        stats: [String: NotebookStats]
    ) -> [Notebook] {
        let comparator: (Notebook, Notebook) -> Bool
        switch self {
        case .manual:
            // 與 server `(sort_order, created_at, id)` 次序一致；created_at 為 server 建立時間（#3677）。
            comparator = { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        case .nameAsc:
            comparator = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc:
            comparator = { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .createdNewest:
            comparator = { $0.createdAt > $1.createdAt }
        case .createdOldest:
            comparator = { $0.createdAt < $1.createdAt }
        case .updatedNewest:
            comparator = { $0.updatedAt > $1.updatedAt }
        case .cardCountDesc:
            comparator = { (stats[$0.remoteId]?.cardCount ?? 0) > (stats[$1.remoteId]?.cardCount ?? 0) }
        case .dueCountDesc:
            comparator = { (stats[$0.remoteId]?.dueCount ?? 0) > (stats[$1.remoteId]?.dueCount ?? 0) }
        case .lastActivity:
            comparator = {
                let l = stats[$0.remoteId]?.lastActivity ?? .distantPast
                let r = stats[$1.remoteId]?.lastActivity ?? .distantPast
                return l > r
            }
        }
        return notebooks.sorted { lhs, rhs in
            // 預設 notebook 永遠最前
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if comparator(lhs, rhs) { return true }
            if comparator(rhs, lhs) { return false }
            // Every equal primary key gets a deterministic order instead of
            // depending on the collection sort implementation's stability.
            return lhs.remoteId < rhs.remoteId
        }
    }
}
