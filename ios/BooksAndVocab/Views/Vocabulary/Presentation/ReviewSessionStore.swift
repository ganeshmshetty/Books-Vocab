import Foundation
import SwiftData

struct ReviewSessionStore {
    private static let legacyKey = "kg.review.shuffledOrder"
    private static let keyPrefix = "kg.review.shuffledOrder.v2"

    private struct Payload: Codable {
        let userScope: String
        let queueFingerprint: String
        let orderedPersistenceIDs: [String]
    }

    /// 保存洗牌後的 entry ID 順序
    static func saveOrder(_ ids: [UUID]) {
        let strings = ids.map(\.uuidString)
        UserDefaults.standard.set(strings, forKey: legacyKey)
    }

    static func saveOrder(
        _ entries: [VocabularyEntry],
        userID: String?,
        defaults: UserDefaults = .standard
    ) {
        let ids = entries.map(persistenceID(for:))
        let payload = Payload(
            userScope: userScope(for: userID),
            queueFingerprint: queueFingerprint(for: entries),
            orderedPersistenceIDs: ids
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey(for: userID))
        }
    }

    /// 讀取已保存的順序，過濾掉已不存在的 entry，並附加新增的 entry
    static func loadOrder(availableEntries: [VocabularyEntry]) -> [VocabularyEntry]? {
        loadOrder(availableEntries: availableEntries, userID: nil)
    }

    static func loadOrder(
        availableEntries: [VocabularyEntry],
        userID: String?,
        allowPartialQueue: Bool = false,
        defaults: UserDefaults = .standard
    ) -> [VocabularyEntry]? {
        guard let data = defaults.data(forKey: storageKey(for: userID)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.userScope == userScope(for: userID),
              !payload.orderedPersistenceIDs.isEmpty else {
            guard userID == nil else { return nil }
            return legacyLoadOrder(availableEntries: availableEntries, defaults: defaults)
        }

        let currentFingerprint = queueFingerprint(for: availableEntries)
        guard allowPartialQueue || payload.queueFingerprint == currentFingerprint else { return nil }

        // sync 競態可能讓兩筆 entry 共用 persistenceID：每個 ID 只佔一個佇列槽位。
        let uniqueEntries = ReviewSessionPersistence.uniqueByPersistenceID(availableEntries)
        let entryMap = Dictionary(
            uniqueEntries.map { (persistenceID(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set<String>()
        let ordered = payload.orderedPersistenceIDs.compactMap { id -> VocabularyEntry? in
            guard seenIDs.insert(id).inserted else { return nil }
            return entryMap[id]
        }
        guard !ordered.isEmpty else { return nil }

        let savedIDSet = Set(payload.orderedPersistenceIDs)
        let newEntries = uniqueEntries.filter { !savedIDSet.contains(persistenceID(for: $0)) }
        let result = ordered + newEntries
        guard !result.isEmpty else { return nil }
        return result
    }

    /// 清除保存的順序
    static func clear() {
        UserDefaults.standard.removeObject(forKey: legacyKey)
        clear(userID: nil)
    }

    static func clear(userID: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(for: userID))
        if userID == nil {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    static func persistenceID(for entry: VocabularyEntry) -> String {
        if let kgCardId = entry.kgCardId, !kgCardId.isEmpty {
            return "kg:\(kgCardId)"
        }
        return "local:\(entry.id.uuidString)"
    }

    private static func storageKey(for userID: String?) -> String {
        "\(keyPrefix).\(userScope(for: userID))"
    }

    private static func userScope(for userID: String?) -> String {
        guard let userID, !userID.isEmpty else { return "guest" }
        return userID
    }

    private static func queueFingerprint(for entries: [VocabularyEntry]) -> String {
        entries.map(persistenceID(for:)).sorted().joined(separator: "|")
    }

    private static func legacyLoadOrder(
        availableEntries: [VocabularyEntry],
        defaults: UserDefaults
    ) -> [VocabularyEntry]? {
        guard let strings = defaults.stringArray(forKey: legacyKey),
              !strings.isEmpty else { return nil }

        let savedIDs = strings.compactMap(UUID.init)
        let entryMap = Dictionary(uniqueKeysWithValues: availableEntries.map { ($0.id, $0) })
        let ordered = savedIDs.compactMap { entryMap[$0] }
        guard !ordered.isEmpty else { return nil }

        let savedIDSet = Set(savedIDs)
        let newEntries = availableEntries.filter { !savedIDSet.contains($0.id) }
        let result = ordered + newEntries
        guard !result.isEmpty else { return nil }
        return result
    }
}
