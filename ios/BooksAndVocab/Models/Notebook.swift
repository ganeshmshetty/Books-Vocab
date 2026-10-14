//
//  Notebook.swift
//  Books & Vocab
//
//  單字本 — 用於分組管理單字

import Foundation
import SwiftData

@Model
final class Notebook {
    // 所有 stored property 都帶 default：對齊 Book / Podcast* 的 CloudKit 慣例。
    // 目前 Notebook 在 local-only store，但補 default 是 behavior-preserving（init 仍覆寫），
    // 並移除「未來若把 Notebook 移入 CloudKit store 會立刻違反『屬性需 optional 或有 default』
    // → ModelContainer init throw → store reset 刪本地資料」的地雷。
    var id: UUID = UUID()
    var remoteId: String = ""
    var name: String = ""
    var color: String?
    var coverPattern: String?
    var coverImagePath: String?
    var sortOrder: Int = 0
    var isDefault: Bool = false
    var createdAt: Date = Date()
    /// 本機首次建立此列的時間（本機時鐘）。`createdAt` 會改存 server 建立時間以跨裝置一致排序，
    /// 因此 reconcile 的 tombstone 守衛必須以本機時間判斷列是否晚於某次 GET 快照（#3675）。
    var localInsertedAt: Date = Date()
    var updatedAt: Date = Date()
    @Attribute(originalName: "isDeleted")
    var isSoftDeleted: Bool = false
    var syncStatus: Int = 0  // 0=pending, 1=synced

    // MARK: - Shared-deck provenance（Explore copy 來源，v1 inert）
    //
    // 由 Explore「複製到我的牌組」（Phase 2）填入；本階段（唯讀 browse）不寫入，
    // 僅隨後端 NotebookResponse（camelCase）跨裝置 round-trip（見 NotebookReconciler）。
    // additive optional → SwiftData lightweight migration 安全，且避免 Phase 2 再遷一次。
    /// 來源共享牌組 deckId（nil = 非複製自 Explore）。
    var sourceSharedDeckId: String?
    /// 複製當下的來源牌組 version（provenance；未來「有新版」anchor）。
    var sourceVersion: Int?

    var isSynced: Bool { syncStatus == 1 }

    init(
        remoteId: String,
        name: String,
        color: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = UUID()
        self.remoteId = remoteId
        self.name = name
        self.color = color
        self.isDefault = isDefault
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
