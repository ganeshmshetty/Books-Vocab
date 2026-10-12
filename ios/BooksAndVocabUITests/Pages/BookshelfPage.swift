import XCTest

/// Page Object for the Bookshelf tab.
struct BookshelfPage {
    let app: XCUIApplication

    // MARK: - Toolbar / Chrome

    var importButton: XCUIElement {
        app.buttons["bookshelf.importButton"]
    }

    var settingsButton: XCUIElement {
        app.buttons["bookshelf.settingsButton"]
    }

    var refreshButton: XCUIElement {
        app.buttons["bookshelf.refreshButton"]
    }

    // MARK: - Content

    var emptyState: XCUIElement {
        app.otherElements["bookshelf.emptyState"]
    }

    var emptyStateImportButton: XCUIElement {
        app.buttons["bookshelf.emptyState.importButton"]
    }

    // MARK: - Book Grid

    private var bookCardsQuery: XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH[c] %@", "book.card."))
    }

    /// Shell readiness: the Bookshelf toolbar import control is mounted in AX.
    /// It is disabled, not removed, while the library is loading, so it exists
    /// as soon as the root tab does, independent of the projected card count.
    @discardableResult
    func waitForShell(timeout: TimeInterval = 30) -> Bool {
        importButton.waitUntilExists(timeout: timeout)
    }

    /// Presence is enough for bookshelf-only state assertions; no element is
    /// returned, so it cannot accidentally become an action shortcut.
    @discardableResult
    func waitForAnyBookCard(timeout: TimeInterval = 5) -> Bool {
        bookCardsQuery.waitUntilAtLeastOne(timeout: timeout)
    }

    /// Legacy read-only probe retained for non-Reader bookshelf smoke flows.
    /// P4/P5 Reader actions must use `exactlyOneBookCard` instead.
    var anyBookCard: XCUIElement {
        bookCardsQuery.firstMatch
    }

    /// Reader flows intentionally require the seeded library to contain one
    /// deterministic book before tapping. This keeps fixture drift visible.
    func exactlyOneBookCard(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) -> XCUIElement? {
        bookCardsQuery.exactlyOneElement(
            timeout: timeout,
            named: "book card",
            file: file,
            line: line
        )
    }

    // MARK: - Actions

    @discardableResult
    func tapImport(file: StaticString = #filePath, line: UInt = UInt(#line)) -> Self {
        importButton.tapWhenReady(file: file, line: line)
        return self
    }

    @discardableResult
    func tapSettings(file: StaticString = #filePath, line: UInt = UInt(#line)) -> SettingsSheetPage {
        // A fixture may apply its localized preferences after the root tab is
        // mounted, causing SwiftUI to rebuild the NavigationStack toolbar.
        // Keep this action bounded but allow that AX projection to settle;
        // the selector remains the production identifier and never falls back
        // to a coordinate or a localized title.
        settingsButton.tapWhenReady(timeout: 15, file: file, line: line)
        return SettingsSheetPage(app: app)
    }

    /// Tap the first available book card, if any.
    @discardableResult
    func tapFirstBook(file: StaticString = #filePath, line: UInt = UInt(#line)) -> ReaderPage? {
        guard bookCardsQuery.waitUntilAtLeastOne(timeout: 5) else { return nil }
        let book = bookCardsQuery.firstMatch
        book.tapWhenReady(file: file, line: line)
        return ReaderPage(app: app)
    }

    // MARK: - Assertions

    func assertIsActive(file: StaticString = #filePath, line: UInt = UInt(#line)) {
        importButton.assertExists(file: file, line: line)
    }

    func assertEmptyStateVisible(file: StaticString = #filePath, line: UInt = UInt(#line)) {
        emptyState.assertExists(file: file, line: line)
    }
}
