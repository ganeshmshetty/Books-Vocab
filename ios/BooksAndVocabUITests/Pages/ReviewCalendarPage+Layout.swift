import XCTest

extension ReviewCalendarPage {
    /// Every addressable day cell button in the month grid, including the
    /// selected one (which carries `reviewCalendar.selectedDay` instead of the
    /// per-day identifier). Blank leading cells are not addressable and are
    /// excluded.
    fileprivate func dayCellButtons() -> XCUIElementQuery {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ OR identifier == %@",
            "reviewCalendar.day.",
            "reviewCalendar.selectedDay"
        )
        return app.buttons.matching(predicate)
    }

    /// Frames of every addressable day cell in the month grid.
    func dayCellFrames() -> [CGRect] {
        let query = dayCellButtons()
        return (0 ..< query.count).map { query.element(boundBy: $0).frame }
    }

    /// Frames of the seven Monday-first weekday header labels, index 0 = Monday.
    /// Returns fewer than seven entries when a header label is missing, so the
    /// caller's count assertion surfaces that instead of a silent mismatch.
    func weekdayHeaderFrames() -> [CGRect] {
        (0 ..< 7).compactMap { index in
            let matches = app.descendants(matching: .any)
                .matching(identifier: weekdayIdentifier(index))
            return matches.count == 1 ? matches.element(boundBy: 0).frame : nil
        }
    }

    /// Number of leading blank cells (Monday-first offset 0...6) in the
    /// displayed month: the column of day 1, which is always in the top row.
    /// Nil when no day cell is addressable.
    func leadingBlankOffset() -> Int? {
        let frames = dayCellFrames()
        let headers = weekdayHeaderFrames()
        guard headers.count == 7,
              let firstDay = frames.min(by: { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY })
        else { return nil }
        return headers.indices.min(by: { abs(headers[$0].midX - firstDay.midX) < abs(headers[$1].midX - firstDay.midX) })
    }

    /// Mirrors `ReviewCalendarAccessibility.weekday(_:)` in the app target,
    /// which the UI test target cannot import.
    private func weekdayIdentifier(_ index: Int) -> String {
        "reviewCalendar.weekday.\(index)"
    }
}

extension ReviewCalendarPage {
    /// Each addressable day cell paired with the frames of its static-text
    /// descendants (the day number), for containment checks.
    func dayCellContents() -> [(cell: CGRect, texts: [CGRect])] {
        let query = dayCellButtons()
        return (0 ..< query.count).map { index in
            let button = query.element(boundBy: index)
            let texts = button.staticTexts.allElementsBoundByIndex.map(\.frame)
            return (button.frame, texts)
        }
    }
}
