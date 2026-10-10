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
}
