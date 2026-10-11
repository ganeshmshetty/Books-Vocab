//
//  VocabularyExporterPOSTests.swift
//  Books & Vocab Tests
//
//  Guards that partOfSpeech is actually emitted in every export format.
//  Regression: CSV header advertised "Part of Speech" but the value was
//  hard-coded empty; JSON/Anki dropped POS entirely.
//

import Foundation
import Testing
@testable import BooksAndVocab

@Suite(.serialized)
struct VocabularyExporterPOSTests {

    private func makeEntry(word: String = "invoke") -> VocabularyEntry {
        VocabularyEntry(
            word: word,
            translation: "引用",
            context: "The lawyer invoked the law.",
            explanation: "to call upon",
            partOfSpeech: "v.",
            bookTitle: "Law 101"
        )
    }

    private func read(_ url: URL?) throws -> String {
        let url = try #require(url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func expectIndependentExports(
        _ export: ([VocabularyEntry]) -> URL?
    ) throws {
        let firstURL = try #require(export([makeEntry()]))
        let firstData = try Data(contentsOf: firstURL)
        defer { try? FileManager.default.removeItem(at: firstURL) }

        let secondURL = try #require(export([makeEntry(word: "cite")]))
        defer { try? FileManager.default.removeItem(at: secondURL) }

        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == firstData)
    }

    @Test func test_csv_emits_part_of_speech() throws {
        let csv = try read(VocabularyExporter.exportAsCSV(entries: [makeEntry()]))
        // Third column (Part of Speech) must carry the value, not "".
        #expect(csv.contains("\"v.\""))
    }

    @Test func test_json_emits_part_of_speech() throws {
        let json = try read(VocabularyExporter.exportAsJSON(entries: [makeEntry()]))
        #expect(json.contains("partOfSpeech"))
        #expect(json.contains("v."))
    }

    @Test func test_anki_emits_part_of_speech() throws {
        let tsv = try read(VocabularyExporter.exportAsAnki(entries: [makeEntry()]))
        #expect(tsv.contains("v."))
    }

    @Test func test_csv_nil_pos_stays_empty() throws {
        let entry = VocabularyEntry(
            word: "the",
            translation: "這",
            context: "the cat",
            bookTitle: "B"
        )
        let csv = try read(VocabularyExporter.exportAsCSV(entries: [entry]))
        // Header + one row. Row column 3 is empty quotes.
        let rows = csv.split(separator: "\n")
        #expect(rows.count == 2)
        #expect(rows[1].contains("\"the\",\"這\",\"\","))
    }

    @Test func test_csv_pos_with_comma_is_escaped() throws {
        let entry = VocabularyEntry(
            word: "set",
            translation: "放",
            context: "set it down",
            partOfSpeech: "v., n.",
            bookTitle: "B"
        )
        let csv = try read(VocabularyExporter.exportAsCSV(entries: [entry]))
        #expect(csv.contains("\"v., n.\""))
    }

    @Test func test_csv_neutralizes_formula_injection() throws {
        let entry = VocabularyEntry(
            word: "+cmd|calc",
            translation: "x",
            context: "=HYPERLINK(\"http://x\",\"y\")",
            partOfSpeech: "n.",
            bookTitle: "@SUM(1)"
        )
        let csv = try read(VocabularyExporter.exportAsCSV(entries: [entry]))
        #expect(csv.contains("\"'=HYPERLINK("))
        #expect(!csv.contains(",\"=HYPERLINK"))
        #expect(csv.contains("\"'+cmd|calc\""))
        #expect(csv.contains("\"'@SUM(1)\""))
    }

    @Test func test_csv_exports_are_independent() throws {
        try expectIndependentExports(VocabularyExporter.exportAsCSV(entries:))
    }

    @Test func test_json_exports_are_independent() throws {
        try expectIndependentExports(VocabularyExporter.exportAsJSON(entries:))
    }

    @Test func test_anki_exports_are_independent() throws {
        try expectIndependentExports(VocabularyExporter.exportAsAnki(entries:))
    }

    @Test func test_csv_starts_with_utf8_bom_and_keeps_chinese() throws {
        let url = try #require(VocabularyExporter.exportAsCSV(entries: [makeEntry()]))
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        // Excel reads BOM-less UTF-8 as ANSI and garbles the Chinese translation.
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"引用\""))
    }

    @Test func test_anki_html_escapes_fields_but_keeps_small_wrapper() throws {
        let entry = VocabularyEntry(
            word: "a<b",
            translation: "x & y > z",
            context: "a<b & c>",
            explanation: "x<y & z",
            partOfSpeech: "a<b",
            bookTitle: "B"
        )
        let tsv = try read(VocabularyExporter.exportAsAnki(entries: [entry]))
        #expect(tsv.contains("<small>a&lt;b &amp; c&gt;</small>"))
        #expect(tsv.contains("a&lt;b<br><small>"))
        #expect(tsv.contains("x &amp; y &gt; z"))
        #expect(!tsv.contains("a<b & c>"))
        // POS and explanation are HTML fields too: escaped, never raw.
        #expect(tsv.contains("(a&lt;b) x &amp; y &gt; z<br>x&lt;y &amp; z"))
        #expect(!tsv.contains("(a<b)"))
        #expect(!tsv.contains("x<y"))
    }

    @Test func test_export_empty_notebook_returns_empty_error_for_every_format() {
        // 守門在 exporter 內：刪掉 guard 會變成 .success，此測試即紅。
        for format in VocabularyExportFormat.allCases {
            #expect(VocabularyExporter.export(entries: [], format: format) == .failure(.empty))
        }
    }

    @Test func test_export_non_empty_notebook_writes_file_for_every_format() throws {
        for format in VocabularyExportFormat.allCases {
            let url = try VocabularyExporter.export(entries: [makeEntry()], format: format).get()
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(FileManager.default.fileExists(atPath: url.path))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("invoke"))
        }
    }

    // #2552：匯出檔保留純檔名（分享時不帶 UUID 前綴），並放在可整包刪除的 per-export 目錄。

    @Test func test_export_keeps_plain_filename_without_uuid_prefix() throws {
        let expected = ["vocabulary.csv", "vocabulary.json", "vocabulary_anki.tsv"]
        for (format, name) in zip(VocabularyExportFormat.allCases, expected) {
            let url = try VocabularyExporter.export(entries: [makeEntry()], format: format).get()
            defer { VocabularyExporter.cleanup(url) }
            #expect(url.lastPathComponent == name)
        }
    }

    @Test func test_cleanup_removes_export_directory_after_dismiss() throws {
        let url = try VocabularyExporter.export(entries: [makeEntry()], format: .csv).get()
        let dir = url.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: url.path))
        VocabularyExporter.cleanup(url)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func test_cleanup_ignores_urls_outside_export_layout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kg-cleanup-guard-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("notes", isDirectory: true)
        let file = dir.appendingPathComponent("keep.csv")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        VocabularyExporter.cleanup(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func test_launch_purge_removes_stale_export_directories() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kg-purge-\(UUID().uuidString)", isDirectory: true)
        let stale = tempRoot
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try "x".write(to: stale.appendingPathComponent("vocabulary.csv"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        VocabularyExporter.purgeStaleExports(in: tempRoot)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("exports").path))
    }
}
