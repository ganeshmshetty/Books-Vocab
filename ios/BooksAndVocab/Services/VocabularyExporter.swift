//
//  VocabularyExporter.swift
//  Books & Vocab
//
//  匯出邏輯 — 純函式型，無狀態、無 UI 依賴
//  將 VocabularyEntry 陣列轉為 CSV / JSON / Anki TSV 並寫入暫存檔
//

import Foundation

enum VocabularyExportFormat: CaseIterable {
    case csv, json, anki
}

enum VocabularyExportError: Error, Equatable {
    /// 沒有可匯出的單字：不產生零列檔案。
    case empty
    /// 暫存檔寫入失敗。
    case writeFailed
}

enum VocabularyExporter {

    // MARK: - Public API

    /// 匯出為 CSV 格式
    static func exportAsCSV(entries: [VocabularyEntry]) -> URL? {
        // U+FEFF BOM：Excel 對 BOM-less UTF-8 會當 ANSI 讀，中文譯文會亂碼。
        var csv = "\u{FEFF}Word,Translation,Part of Speech,Context,Book,Chapter,Date\n"
        for entry in entries {
            let fields = [
                escapeCSV(entry.word),
                escapeCSV(entry.translation),
                escapeCSV(entry.partOfSpeech ?? ""),
                escapeCSV(entry.context),
                escapeCSV(entry.bookTitle),
                escapeCSV(entry.chapterTitle ?? ""),
                escapeCSV(entry.dateAdded.formatted(.iso8601))
            ]
            csv += fields.joined(separator: ",") + "\n"
        }
        return saveToTemp(content: csv, filename: "vocabulary.csv")
    }

    /// 匯出為 JSON 格式
    static func exportAsJSON(entries: [VocabularyEntry]) -> URL? {
        let items = entries.map { entry -> [String: String] in
            var dict: [String: String] = [
                "word": entry.word,
                "translation": entry.translation,
                "context": entry.context,
                "bookTitle": entry.bookTitle,
                "dateAdded": entry.dateAdded.formatted(.iso8601)
            ]

            if let exp = entry.explanation { dict["explanation"] = exp }
            if let pos = entry.partOfSpeech { dict["partOfSpeech"] = pos }
            if let ch = entry.chapterTitle { dict["chapterTitle"] = ch }
            return dict
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: items, options: .prettyPrinted),
            let json = String(data: data, encoding: .utf8)
        else { return nil }

        return saveToTemp(content: json, filename: "vocabulary.json")
    }

    /// 匯出為 Anki TSV 格式
    static func exportAsAnki(entries: [VocabularyEntry]) -> URL? {
        var tsv = ""
        for entry in entries {
            let front = "\(escapeHTML(entry.word))\n<small>\(escapeHTML(entry.context))</small>"
            var back = escapeHTML(entry.translation)

            if let pos = entry.partOfSpeech, !pos.isEmpty { back = "(\(escapeHTML(pos))) \(back)" }
            if let exp = entry.explanation { back += "\n\(escapeHTML(exp))" }

            tsv += "\(escapeTab(front))\t\(escapeTab(back))\n"
        }
        return saveToTemp(content: tsv, filename: "vocabulary_anki.tsv")
    }

    /// 唯一的 UI 匯出入口。空清單在此短路（不產生零列檔案），呼叫端只負責把結果映射為 UI。
    static func export(
        entries: [VocabularyEntry],
        format: VocabularyExportFormat
    ) -> Result<URL, VocabularyExportError> {
        guard !entries.isEmpty else { return .failure(.empty) }
        let url: URL?
        switch format {
        case .csv: url = exportAsCSV(entries: entries)
        case .json: url = exportAsJSON(entries: entries)
        case .anki: url = exportAsAnki(entries: entries)
        }
        guard let url else { return .failure(.writeFailed) }
        return .success(url)
    }

    // MARK: - Internal Helpers

    /// 每次匯出各自一個 `<tmp>/exports/<UUID>/` 目錄，檔名保持純淨（`vocabulary_*.{csv,json,tsv}`）。
    private static func saveToTemp(content: String, filename: String) -> URL? {
        let dir = exportsRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// 分享結束（sheet dismiss）後刪除該次匯出的目錄。只接受 `<tmp>/exports/<UUID>/<file>` 精確結構，
    /// 其他路徑一律不動，避免誤刪非匯出檔案。
    static func cleanup(_ url: URL?) {
        guard let url else { return }
        let dir = url.deletingLastPathComponent()
        guard dir.deletingLastPathComponent().standardizedFileURL.path == exportsRoot().standardizedFileURL.path,
              UUID(uuidString: dir.lastPathComponent) != nil
        else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// App 啟動時清掉上次 session 殘留（未走到 dismiss 的）匯出目錄；純 file I/O，呼叫端不阻塞啟動。
    static func purgeStaleExports(in tempDirectory: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: exportsRoot(in: tempDirectory))
    }

    private static func exportsRoot(in tempDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        tempDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    private static func escapeCSV(_ text: String) -> String {
        // 防試算表公式注入：欄位內容來自不受信任的書籍，開頭為公式觸發字元時
        // 前置 `'` 讓 Excel/Numbers/Sheets 視為純文字（會改動資料，屬已知取捨）。
        let formulaTriggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r", "\n"]
        let safe = text.first.map(formulaTriggers.contains) == true ? "'" + text : text
        let escaped = safe.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Anki 欄位為 HTML；`&` 必須先轉義，否則後續實體會被二次轉義。
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeTab(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
