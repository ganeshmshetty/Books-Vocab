import Foundation
import XCTest

// UI tests are intentionally black-box: XCTest UI bundles do not link the app
// executable, so their evidence DTOs must not depend on app-internal symbols.
// Keep this wire contract byte-for-byte compatible with the app-side
// ReaderTOCEvidence* types in Views/Reader/ReaderViewState.swift.
enum ReaderTOCEvidenceHref {
    /// Readium locators report only the resource href; TOC hrefs may add `#fragment`.
    static func resourceHref(_ href: String) -> String {
        guard let hash = href.firstIndex(of: "#") else { return href }
        return String(href[..<hash])
    }

    static func isSafeRelative(_ href: String) -> Bool {
        guard !href.isEmpty,
              href == href.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.hasPrefix("/"),
              !href.hasPrefix("\\"),
              !href.contains("\\"),
              href.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }),
              let url = URL(string: href),
              url.scheme == nil,
              url.host == nil,
              let decoded = href.removingPercentEncoding else {
            return false
        }

        let path = decoded.split(whereSeparator: { $0 == "?" || $0 == "#" }).first
            ?? Substring(decoded)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct ReaderTOCEvidenceContext: Codable, Equatable {
    struct Invocation: Codable, Equatable {
        let verdictFile: String
    }

    static let schema = "kg.ui.perf.evidence.context.v1"
    let schema: String
    let invocation: Invocation
    var selectors: [String]
    let screenshotDirectory: String
    var screenshotPath: String
    var entries: [ReaderTOCEvidenceEntry]

    var validationErrors: [String] {
        var errors: [String] = []
        if schema != Self.schema { errors.append("schema") }
        if invocation.verdictFile.isEmpty || !invocation.verdictFile.hasPrefix("/") {
            errors.append("invocation.verdictFile")
        }
        if selectors.isEmpty || selectors.contains(where: { $0.isEmpty }) {
            errors.append("selectors")
        }
        if screenshotDirectory.isEmpty || !screenshotDirectory.hasPrefix("/") {
            errors.append("screenshotDirectory")
        }
        if screenshotPath.isEmpty || !screenshotPath.hasPrefix("/") {
            errors.append("screenshotPath")
        }
        errors.append(contentsOf: ReaderTOCEvidenceEntry.validationErrors(for: entries))
        return errors
    }

    var completeValidationErrors: [String] {
        var errors = validationErrors
        let required = entries.filter { $0.partition == "required" }
        let counterexamples = entries.filter { $0.partition == "counterexample" }
        if required.count != 1 { errors.append("partitions.required.count") }
        if counterexamples.count != 2 { errors.append("partitions.counterexample.count") }
        if entries.contains(where: { !["required", "counterexample"].contains($0.partition) }) {
            errors.append("partitions.disjoint")
        }
        if !Set(required.map(\.label)).intersection(Set(counterexamples.map(\.label))).isEmpty {
            errors.append("partitions.labelsOverlap")
        }
        if !Set(required.map(\.fixtureID)).intersection(Set(counterexamples.map(\.fixtureID))).isEmpty {
            errors.append("partitions.fixturesOverlap")
        }
        if !Set(required.map { $0.asset.assetID }).intersection(Set(counterexamples.map { $0.asset.assetID })).isEmpty {
            errors.append("partitions.assetsOverlap")
        }
        return errors
    }
}

struct ReaderTOCEvidenceAsset: Codable, Equatable {
    let assetID: String
    let installedPath: String
    let expectedSHA256: String
    let expectedByteSize: Int
    let actualSHA256: String
    let actualByteSize: Int
}

struct ReaderTOCEvidenceSelectedRow: Codable, Equatable {
    let path: [Int]
    let href: String
    let title: String
}

struct ReaderTOCEvidenceObservation: Codable, Equatable {
    let requestedHref: String
    let observedLocatorHref: String?
    let observedContent: String?
    let contentSelector: String?
}

struct ReaderTOCEvidenceEntry: Codable, Equatable {
    let label: String
    let partition: String
    let fixtureID: String
    let asset: ReaderTOCEvidenceAsset
    let path: [Int]
    let selectedRow: ReaderTOCEvidenceSelectedRow
    let observation: ReaderTOCEvidenceObservation

    static func validationErrors(for entries: [ReaderTOCEvidenceEntry]) -> [String] {
        var errors: [String] = []
        for (index, entry) in entries.enumerated() {
            let prefix = "entries[\(index)]"
            if entry.label.isEmpty { errors.append("\(prefix).label") }
            if !["required", "counterexample"].contains(entry.partition) {
                errors.append("\(prefix).partition")
            }
            if entry.fixtureID.isEmpty { errors.append("\(prefix).fixtureID") }
            if !entry.asset.assetID.hasPrefix("books.") { errors.append("\(prefix).asset.assetID") }
            if entry.asset.installedPath.isEmpty || !entry.asset.installedPath.hasPrefix("/") {
                errors.append("\(prefix).asset.installedPath")
            }
            if entry.asset.expectedSHA256.count != 64 { errors.append("\(prefix).asset.expectedSHA256") }
            if entry.asset.actualSHA256.count != 64 { errors.append("\(prefix).asset.actualSHA256") }
            if !entry.asset.expectedSHA256.allSatisfy(\.isHexDigit) {
                errors.append("\(prefix).asset.expectedSHA256")
            }
            if !entry.asset.actualSHA256.allSatisfy(\.isHexDigit) {
                errors.append("\(prefix).asset.actualSHA256")
            }
            if entry.asset.expectedByteSize <= 0 { errors.append("\(prefix).asset.expectedByteSize") }
            if entry.asset.actualByteSize <= 0 { errors.append("\(prefix).asset.actualByteSize") }
            if entry.asset.expectedSHA256 != entry.asset.actualSHA256 {
                errors.append("\(prefix).asset.sha256Mismatch")
            }
            if entry.asset.expectedByteSize != entry.asset.actualByteSize {
                errors.append("\(prefix).asset.byteSizeMismatch")
            }
            if entry.path.contains(where: { $0 < 0 }) { errors.append("\(prefix).path") }
            if entry.selectedRow.path != entry.path {
                errors.append("\(prefix).selectedRow.pathMismatch")
            }
            if entry.selectedRow.href.isEmpty || entry.selectedRow.href != entry.observation.requestedHref {
                errors.append("\(prefix).selectedRow.hrefMismatch")
            }
            if entry.selectedRow.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("\(prefix).selectedRow.title")
            }
            if entry.observation.requestedHref.isEmpty {
                errors.append("\(prefix).observation.requestedHref")
            }
            if !ReaderTOCEvidenceHref.isSafeRelative(entry.observation.requestedHref) {
                errors.append("\(prefix).observation.unsafeHref")
            }
            switch entry.partition {
            case "required":
                if entry.observation.observedLocatorHref != ReaderTOCEvidenceHref.resourceHref(entry.observation.requestedHref) {
                    errors.append("\(prefix).observation.locatorMismatch")
                }
                if entry.observation.contentSelector?.isEmpty != false
                    || entry.observation.observedContent?.isEmpty != false {
                    errors.append("\(prefix).observation.content")
                }
            case "counterexample":
                if entry.observation.observedLocatorHref == nil
                    || entry.observation.observedLocatorHref == ReaderTOCEvidenceHref.resourceHref(entry.observation.requestedHref) {
                    errors.append("\(prefix).observation.counterexampleLocator")
                }
                if entry.observation.contentSelector != nil || entry.observation.observedContent != nil {
                    errors.append("\(prefix).observation.counterexampleContent")
                }
            default:
                break
            }
        }
        return errors
    }
}

private enum ReaderTOCEvidenceWriterError: Error, CustomStringConvertible {
    case missingInvocationContext
    case invalidContext(String)
    case missingAccessibilityObservation(String)
    case observationMismatch(String)
    case assetIntegrityMismatch(String)
    case missingScreenshot

    var description: String {
        switch self {
        case .missingInvocationContext:
            return "pre-run Reader evidence context requires KG_IOS_VERDICT_FILE"
        case .invalidContext(let field):
            return "Reader evidence context is invalid: \(field)"
        case .missingAccessibilityObservation(let identifier):
            return "current Reader accessibility observation is missing \(identifier)"
        case .observationMismatch(let field):
            return "Reader observation does not match \(field)"
        case .assetIntegrityMismatch(let field):
            return "Reader evidence asset does not match canonical fixture \(field)"
        case .missingScreenshot:
            return "current Reader screenshot path is missing"
        }
    }
}

extension UITestCase {
    /// Records only identity/context and observations available during the UI
    /// body. It deliberately never opens the runner's final verdict JSON. The
    /// canonical `ios_test.sh` UI bundle retains this XCTest attachment,
    /// screenshot directory, xcresult, and invocation verdict path together.
    func writeReaderTOCEvidence(
        label: String,
        partition: String,
        fixtureID: String,
        assetID: String,
        path: [Int],
        href: String,
        locatorHref: String?,
        destinationSelector: String? = nil,
        contentSelector: String? = nil,
        observedContent: String? = nil,
        selectedRowObservation: ReaderTOCEvidenceSelectedRow? = nil
    ) throws {
        guard !label.isEmpty, !fixtureID.isEmpty, !assetID.isEmpty, !href.isEmpty else {
            throw ReaderTOCEvidenceWriterError.invalidContext("entry identity")
        }
        guard ReaderTOCEvidenceHref.isSafeRelative(href) else {
            throw ReaderTOCEvidenceWriterError.invalidContext("unsafe href")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let verdictFile = Self.preRunVerdictFile(from: environment) else {
            throw ReaderTOCEvidenceWriterError.missingInvocationContext
        }
        guard let screenshotDirectory = environment["KG_UI_TEST_SCREENSHOT_DIR"],
              !screenshotDirectory.isEmpty,
              let screenshotPath = lastCapturedScreenshotPath,
              screenshotPath.hasPrefix(screenshotDirectory + "/"),
              FileManager.default.fileExists(atPath: screenshotPath) else {
            throw ReaderTOCEvidenceWriterError.missingScreenshot
        }
        let app = try XCTUnwrap(currentApp)
        // Readium may rebuild the WebKit AX subtree after any subsequent
        // cross-surface query. Prefer the exact content observation captured
        // by the Page Object immediately after its assertion; only legacy
        // callers without an observation use the bounded fallback reader.
        let contentObservation: String?
        if let observedContent {
            contentObservation = observedContent
        } else {
            contentObservation = try Self.readContent(
                app,
                selector: contentSelector
            )
        }
        let asset = try Self.readInstalledAsset(from: app, assetID: assetID)
        let observedLocator = try Self.readRequiredValue(
            app,
            identifier: "reader.currentLocator"
        )
        let selectedRow: ReaderTOCEvidenceSelectedRow
        if let selectedRowObservation {
            guard selectedRowObservation.path == path,
                  selectedRowObservation.href == href,
                  !selectedRowObservation.title.isEmpty else {
                throw ReaderTOCEvidenceWriterError.observationMismatch("selectedRow")
            }
            selectedRow = selectedRowObservation
        } else {
            selectedRow = try Self.readSelectedRow(
                app,
                path: path,
                expectedHref: href
            )
        }
        if let locatorHref, locatorHref != observedLocator {
            throw ReaderTOCEvidenceWriterError.observationMismatch("locatorHref")
        }
        if let destinationSelector {
            let destination = try Self.readScopedValue(
                app,
                rootIdentifier: "reader.toc.readerOverlay",
                identifier: destinationSelector
            )
            guard destination == observedLocator else {
                throw ReaderTOCEvidenceWriterError.observationMismatch(
                    "destinationSelector"
                )
            }
        }

        let entry = ReaderTOCEvidenceEntry(
            label: label,
            partition: partition,
            fixtureID: fixtureID,
            asset: asset,
            path: path,
            selectedRow: selectedRow,
            observation: ReaderTOCEvidenceObservation(
                requestedHref: href,
                observedLocatorHref: observedLocator,
                observedContent: contentObservation,
                contentSelector: contentSelector
            )
        )
        let contextURL = URL(fileURLWithPath: screenshotDirectory)
            .appendingPathComponent("reader-toc-ui-context.json")
        var context: ReaderTOCEvidenceContext
        if FileManager.default.fileExists(atPath: contextURL.path) {
            context = try JSONDecoder().decode(
                ReaderTOCEvidenceContext.self,
                from: Data(contentsOf: contextURL)
            )
            guard context.invocation.verdictFile == verdictFile,
                  context.screenshotDirectory == screenshotDirectory else {
                throw ReaderTOCEvidenceWriterError.invalidContext("invocation or screenshot identity")
            }
        } else {
            context = ReaderTOCEvidenceContext(
                schema: ReaderTOCEvidenceContext.schema,
                invocation: ReaderTOCEvidenceContext.Invocation(verdictFile: verdictFile),
                selectors: [],
                screenshotDirectory: screenshotDirectory,
                screenshotPath: screenshotPath,
                entries: []
            )
        }
        if !context.selectors.contains(name) {
            context.selectors.append(name)
        }
        context.screenshotPath = screenshotPath
        context.entries.append(entry)
        let errors = context.entries.count >= 3
            ? context.completeValidationErrors
            : context.validationErrors
        guard errors.isEmpty else {
            throw ReaderTOCEvidenceWriterError.invalidContext(errors.joined(separator: ","))
        }
        let encoded = try JSONEncoder.readerTOCEvidence.encode(context)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: screenshotDirectory),
            withIntermediateDirectories: true
        )
        try encoded.write(to: contextURL, options: .atomic)
        let reparsed = try JSONDecoder().decode(
            ReaderTOCEvidenceContext.self,
            from: Data(contentsOf: contextURL)
        )
        guard reparsed.validationErrors.isEmpty else {
            throw ReaderTOCEvidenceWriterError.invalidContext("persisted context")
        }
        attachText(
            String(decoding: encoded, as: UTF8.self),
            named: "KG_PERF UI Evidence Context \(label)"
        )
    }

    private static func preRunVerdictFile(
        from environment: [String: String]
    ) -> String? {
        if let path = environment["KG_IOS_VERDICT_FILE"], !path.isEmpty {
            return path
        }
        if let jsonPath = environment["KG_UI_TEST_VERDICT_JSON"], !jsonPath.isEmpty {
            return jsonPath.hasSuffix(".json")
                ? String(jsonPath.dropLast(5))
                : jsonPath
        }
        return nil
    }

    private static func readSelectedRow(
        _ app: XCUIApplication,
        path: [Int],
        expectedHref: String
    ) throws -> ReaderTOCEvidenceSelectedRow {
        guard ReaderTOCEvidenceHref.isSafeRelative(expectedHref) else {
            throw ReaderTOCEvidenceWriterError.invalidContext("unsafe selected row href")
        }
        let pathID = path.map(String.init).joined(separator: ".")
        let identifier = "reader.toc.chapter.\(pathID)"
        let rows = app.buttons.matching(identifier: identifier)
        guard rows.count == 1,
              let row = rows.allElementsBoundByIndex.first,
              row.exists,
              !row.label.isEmpty,
              let value = row.value as? String,
              !value.isEmpty else {
            throw ReaderTOCEvidenceWriterError.missingAccessibilityObservation(identifier)
        }
        guard ReaderTOCEvidenceHref.isSafeRelative(value), value == expectedHref else {
            throw ReaderTOCEvidenceWriterError.observationMismatch("selectedRow.href")
        }
        return ReaderTOCEvidenceSelectedRow(
            path: path,
            href: value,
            title: row.label
        )
    }

    private static func readInstalledAsset(
        from app: XCUIApplication,
        assetID: String
    ) throws -> ReaderTOCEvidenceAsset {
        let descriptor = try readRequiredValue(app, identifier: "reader.evidence.asset")
        let parts = descriptor.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 6,
              let expectedByteSize = Int(parts[3]),
              let actualByteSize = Int(parts[5]),
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[2].count == 64,
              parts[4].count == 64 else {
            throw ReaderTOCEvidenceWriterError.missingAccessibilityObservation(
                "reader.evidence.asset"
            )
        }
        guard String(parts[0]) == assetID else {
            throw ReaderTOCEvidenceWriterError.assetIntegrityMismatch("assetID")
        }
        let installedURL = URL(fileURLWithPath: String(parts[1]))
        guard installedURL.path.hasPrefix("/"),
              installedURL.deletingLastPathComponent().lastPathComponent == "Books",
              installedURL.path
                  == installedURL.deletingLastPathComponent()
                      .appendingPathComponent(installedURL.lastPathComponent)
                      .path else {
            throw ReaderTOCEvidenceWriterError.assetIntegrityMismatch(
                "installed-path"
            )
        }
        return ReaderTOCEvidenceAsset(
            assetID: assetID,
            installedPath: installedURL.path,
            expectedSHA256: String(parts[2]),
            expectedByteSize: expectedByteSize,
            actualSHA256: String(parts[4]),
            actualByteSize: actualByteSize
        )
    }

    private static func readContent(
        _ app: XCUIApplication,
        selector: String?
    ) throws -> String? {
        guard let selector, !selector.isEmpty else { return nil }
        let readerSurface = app.otherElements["reader.webView.settingsState"]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            // Readium exposes multiple WebKit projections. Scope the content
            // observation to the production surface container instead of
            // assuming a projection count or order.
            let contentQuery = readerSurface.staticTexts.matching(identifier: selector)
            if readerSurface.exists, contentQuery.count == 1 {
                let content = readerSurface.staticTexts[selector]
                if content.exists { return content.label }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw ReaderTOCEvidenceWriterError.missingAccessibilityObservation(
            "contentSelector:\(selector)"
        )
    }

    private static func readScopedValue(
        _ app: XCUIApplication,
        rootIdentifier: String,
        identifier: String
    ) throws -> String {
        let roots = app.otherElements.matching(identifier: rootIdentifier)
        guard roots.count == 1,
              let root = roots.allElementsBoundByIndex.first else {
            throw ReaderTOCEvidenceWriterError.missingAccessibilityObservation(rootIdentifier)
        }
        let elements = root.staticTexts.matching(identifier: identifier)
        guard elements.count == 1,
              let element = elements.allElementsBoundByIndex.first,
              let value = element.value as? String,
              !value.isEmpty else {
            throw ReaderTOCEvidenceWriterError.missingAccessibilityObservation(identifier)
        }
        return value
    }

    private static func readRequiredValue(
        _ app: XCUIApplication,
        identifier: String
    ) throws -> String {
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        let elements = app.staticTexts.matching(predicate)
        let element = app.staticTexts.element(matching: predicate)
        guard elements.count == 1,
              element.exists,
              let value = element.value as? String,
              !value.isEmpty else {
            throw ReaderTOCEvidenceWriterError.missingAccessibilityObservation(identifier)
        }
        return value
    }
}

private extension JSONEncoder {
    static var readerTOCEvidence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
