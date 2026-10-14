//
//  NotebookCoverStore.swift
//  Books & Vocab
//
//  單字本自訂封面（device-local JPEG）的唯一路徑解析點（#3676）。
//
//  持久化值只存檔名（`notebook_cover_<UUID>.jpg`）。絕對路徑內含 app data container UUID，
//  還原備份／換機後 UUID 改變，舊值會指向不存在的檔案。讀取與刪除一律經此處解析；
//  舊版存下的絕對路徑也以檔名映射到目前的 `Documents/NotebookCovers`，免資料遷移。
//

import Foundation

enum NotebookCoverStore {

    static let directoryName = "NotebookCovers"

    /// 目前 container 的封面目錄（nil = 無 Documents 目錄，實務上不會發生）。
    static func directoryURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 持久化時使用的檔名（去掉任何容器前綴）。
    static func fileName(_ stored: String) -> String {
        URL(fileURLWithPath: stored).lastPathComponent
    }

    /// 兩個封面值是否指向同一檔案（以檔名比較，忽略容器前綴差異）。
    static func isSameCover(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return fileName(left) == fileName(right)
        default:
            return false
        }
    }

    /// 將持久化值（檔名或舊版絕對路徑）解析為目前 container 內的檔案路徑。
    /// 絕對路徑仍存在時沿用（同一 container 內的既有檔、尚未 commit 的新檔）；
    /// 否則以檔名映射到目前的封面目錄。
    static func resolvePath(_ stored: String?, fileManager: FileManager = .default) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("/"), fileManager.fileExists(atPath: stored) {
            return stored
        }
        return directoryURL(fileManager: fileManager)?
            .appendingPathComponent(fileName(stored))
            .path
    }

    /// 讀取封面 bytes；解析失敗或檔案不存在時回傳 nil。
    static func loadData(_ stored: String) -> Data? {
        guard let path = resolvePath(stored) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// 刪除封面檔（best-effort）。
    static func remove(_ stored: String?) {
        guard let path = resolvePath(stored) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
