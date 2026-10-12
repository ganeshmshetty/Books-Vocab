import Testing
@testable import BooksAndVocab

/// #3135 — unit selection for the grade-button interval hint: hours under a day,
/// days (one decimal under 10 days, integer under 60), then rounded months.
struct ReviewIntervalFormatterTests {
    private static func parts(_ hours: Double) -> ReviewIntervalFormatter.Components {
        ReviewIntervalFormatter.components(hours: hours)
    }

    @Test func subDayIntervalsReadAsWholeHours() {
        #expect(Self.parts(12) == .init(unit: .hours, value: 12))
        #expect(Self.parts(23.4) == .init(unit: .hours, value: 23))
        #expect(Self.parts(0.4) == .init(unit: .hours, value: 1), "never shows 0 hours")
    }

    @Test func underTenDaysKeepsOneDecimalAndDropsTrailingZero() {
        #expect(Self.parts(24) == .init(unit: .days, value: 1))
        #expect(Self.parts(60) == .init(unit: .days, value: 2.5))
        #expect(Self.parts(24 * 3) == .init(unit: .days, value: 3), "3.0 days reads as 3")
        #expect(Self.parts(24 * 2.25) == .init(unit: .days, value: 2.3), "rounds to one decimal")
    }

    @Test func tenToSixtyDaysReadAsWholeDays() {
        #expect(Self.parts(24 * 10) == .init(unit: .days, value: 10))
        #expect(Self.parts(24 * 59 + 6) == .init(unit: .days, value: 59))
    }

    @Test func sixtyDaysAndUpReadAsRoundedMonths() {
        #expect(Self.parts(24 * 60) == .init(unit: .months, value: 2))
        #expect(Self.parts(24 * 90) == .init(unit: .months, value: 3))
    }

    @Test func textUsesTheUnitWordForItsComponent() {
        #expect(
            ReviewIntervalFormatter.text(hours: 60)
                == L10n.format("todayReview.interval.days", ReviewIntervalFormatter.number(2.5))
        )
        #expect(
            ReviewIntervalFormatter.text(hours: 24 * 90)
                == L10n.format("todayReview.interval.months", ReviewIntervalFormatter.number(3))
        )
    }
}
