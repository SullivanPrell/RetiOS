import XCTest
@testable import RetiOS

/// Covers the list-row date formatting that replaced `Text(_, style: .relative)`.
///
/// The bug being locked down: `.relative` renders a bare *duration*, so a
/// conversation last touched yesterday evening displayed as "21 hr, 3 min" —
/// a countdown, not a statement about when something happened.
///
/// Every case pins an explicit `now` rather than reading the clock, so the
/// suite can't pass or fail depending on the hour it runs.
final class RNSDateTests: XCTestCase {

    private let cal = Calendar.current

    /// 2026-07-22, 14:30 local — an arbitrary but fixed "now".
    private var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 7, day: 22,
                                      hour: 14, minute: 30))!
    }

    private func date(_ offset: DateComponents) -> Date {
        cal.date(byAdding: offset, to: now)!
    }

    // MARK: - listTimestamp

    func testTodayShowsClockTime() {
        let earlierToday = date(DateComponents(hour: -3))   // 11:30 same day
        let out = RNSDate.listTimestamp(earlierToday, now: now)

        // Locale decides 12- vs 24-hour, so assert against the same formatting
        // the app would use rather than a hard-coded "11:30 AM".
        XCTAssertEqual(out, earlierToday.formatted(date: .omitted, time: .shortened))
        XCTAssertFalse(out.contains("hr"), "a duration leaked back in: \(out)")
    }

    func testYesterdayIsNamed() {
        // 21 h before 14:30 is 17:30 the previous day — precisely the case that
        // rendered as "21 hr, 3 min" in the conversation list.
        let yesterdayEvening = date(DateComponents(hour: -21))
        XCTAssertEqual(RNSDate.listTimestamp(yesterdayEvening, now: now), "Yesterday")
    }

    func testWithinTheLastWeekShowsWeekday() {
        let threeDaysAgo = date(DateComponents(day: -3))
        XCTAssertEqual(RNSDate.listTimestamp(threeDaysAgo, now: now),
                       threeDaysAgo.formatted(.dateTime.weekday(.abbreviated)))
    }

    func testOlderThanAWeekShowsDate() {
        let longAgo = date(DateComponents(day: -30))
        XCTAssertEqual(RNSDate.listTimestamp(longAgo, now: now),
                       longAgo.formatted(date: .numeric, time: .omitted))
    }

    /// The 7-day boundary is where "weekday" stops being unambiguous: a date
    /// exactly a week back has the *same* weekday name as today, so it must
    /// fall through to a full date.
    func testSevenDaysAgoIsADateNotAWeekday() {
        let sevenDaysAgo = date(DateComponents(day: -7))
        XCTAssertEqual(RNSDate.listTimestamp(sevenDaysAgo, now: now),
                       sevenDaysAgo.formatted(date: .numeric, time: .omitted))
    }

    // MARK: - ago

    func testAgoReadsAsElapsedTime() {
        let out = RNSDate.ago(date(DateComponents(hour: -21)), now: now)
        // Wording is localized; what matters is that it's phrased as elapsed
        // time and not the bare "21 hr, 3 min" duration this replaced.
        XCTAssertFalse(out.isEmpty)
        XCTAssertNotEqual(out, "21 hr, 3 min")
        XCTAssertTrue(out.lowercased().contains("hour") || out.lowercased().contains("ago"),
                      "expected an elapsed-time phrase, got: \(out)")
    }

    func testAgoNamesYesterdayRatherThanCountingDays() {
        // `.named` is why this says "yesterday" instead of "1 day ago".
        let out = RNSDate.ago(date(DateComponents(day: -1)), now: now).lowercased()
        XCTAssertTrue(out.contains("yesterday"), "expected a named day, got: \(out)")
    }
}
