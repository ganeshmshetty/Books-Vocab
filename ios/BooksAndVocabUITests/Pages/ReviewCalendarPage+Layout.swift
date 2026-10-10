import XCTest

extension ReviewCalendarPage {
    /// Frames of every addressable day cell in the month grid, including the
    /// selected one (which carries `reviewCalendar.selectedDay` instead of the
    /// per-day identifier). Blank leading cells are not addressable and are
    /// excluded.
    func dayCellFrames() -> [CGRect] {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ OR identifier == %@",
            "reviewCalendar.day.",
            "reviewCalendar.selectedDay"
        )
        let query = app.buttons.matching(predicate)
        return (0 ..< query.count).map { query.element(boundBy: $0).frame }
    }

    /// Frames of the seven Monday-first weekday header labels, index 0 = Monday.
    /// Returns fewer than seven entries when a header label is missing, so the
    /// caller's count assertion surfaces that instead of a silent mismatch.
    func weekdayHeaderFrames() -> [CGRect] {
        (0 ..< 7).compactMap { index in
            let matches = app.descendants(matching: .any)
                .matching(identifier: "reviewCalendar.weekday.\(index)")
            return matches.count == 1 ? matches.element(boundBy: 0).frame : nil
        }
    }
}
