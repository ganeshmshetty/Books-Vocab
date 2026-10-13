//
//  SharedDeckCopyIntentStore.swift
//  Books & Vocab
//
//  Explore 複製「待完成意圖」的持久化（#3423）。意圖 = 一把 idempotencyKey + 目標 notebook 名稱，
//  在複製開始時落盤、成功時清除。行程在回應前被殺後，重啟的 registry 以同一把 key 接回，
//  retry 由 server 依 (copier, key) 冪等短路，避免 memory-only key 重生成 UUID 而重複複製。
//  結構與 `PendingLinkCreationStore` 對齊；只存複製意圖，不存 server 回應或 notebook 內容。
//

import Foundation

/// 一次尚未確認成功的複製意圖（以 owner + deckId 為鍵）。
struct PendingDeckCopyIntent: Codable, Equatable {
    /// 擁有此意圖的帳號（未登入為 nil）。key 不得跨帳號流用（#2748）。
    let owner: String?
    let deckId: String
    let idempotencyKey: String
    let notebookName: String?
}

protocol SharedDeckCopyIntentStoring: AnyObject {
    func load() -> [PendingDeckCopyIntent]
    func save(_ intents: [PendingDeckCopyIntent])
}

extension SharedDeckCopyIntentStoring {
    /// 同 (owner, deckId) 的意圖以新值取代（一個 deck 同帳號僅一個待完成意圖）。
    func upsert(_ intent: PendingDeckCopyIntent) {
        var all = load().filter { !($0.owner == intent.owner && $0.deckId == intent.deckId) }
        all.append(intent)
        save(all)
    }

    func remove(owner: String?, deckId: String) {
        save(load().filter { !($0.owner == owner && $0.deckId == deckId) })
    }
}

final class UserDefaultsSharedDeckCopyIntentStore: SharedDeckCopyIntentStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "kg.explore.pendingDeckCopies.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [PendingDeckCopyIntent] {
        guard let data = defaults.data(forKey: key),
              let intents = try? JSONDecoder().decode([PendingDeckCopyIntent].self, from: data)
        else { return [] }
        return intents
    }

    func save(_ intents: [PendingDeckCopyIntent]) {
        if intents.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(intents) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 不落盤的實作：單元測試預設值，以及 `-isolatedAuthSession` UI-test run（同 `EphemeralPendingLinkCreationStore`
/// 的 hermetic 契約，避免上一個 UI test 的待完成複製洩漏到下一個）。
final class EphemeralSharedDeckCopyIntentStore: SharedDeckCopyIntentStoring {
    private var intents: [PendingDeckCopyIntent]

    init(intents: [PendingDeckCopyIntent] = []) { self.intents = intents }

    func load() -> [PendingDeckCopyIntent] { intents }
    func save(_ intents: [PendingDeckCopyIntent]) { self.intents = intents }
}

enum SharedDeckCopyIntentStores {
    /// Composition root：App 內持久化，isolated UI test 下為 ephemeral。
    static func makeDefault(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> any SharedDeckCopyIntentStoring {
        if AppRuntimeOptions.shouldUseIsolatedAuthSession(arguments: arguments) {
            return EphemeralSharedDeckCopyIntentStore()
        }
        return UserDefaultsSharedDeckCopyIntentStore(defaults: defaults)
    }
}
