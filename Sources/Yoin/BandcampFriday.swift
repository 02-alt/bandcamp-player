import Foundation

/// Bandcamp Friday — the recurring day (historically the first Friday of the month) when
/// Bandcamp waives its revenue share, so effectively ~100% of a purchase reaches the artist.
/// We can't know Bandcamp's exact published schedule, so we use the first-Friday heuristic.
enum BandcampFriday {
    /// True when `date` is the first Friday of its month.
    static func isToday(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .day], from: date)
        return c.weekday == 6 && (c.day ?? 99) <= 7   // Gregorian: Sunday = 1 … Friday = 6
    }

    /// The next first-Friday-of-month on or after `date` (nil only if the calendar misbehaves).
    static func next(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<45 {
            if isToday(day, calendar: calendar) { return day }
            guard let n = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = n
        }
        return nil
    }

    /// A short human label for the next Bandcamp Friday, e.g. "Fri 2 Oct".
    static func nextLabel(from date: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let d = next(after: date, calendar: calendar) else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("EEEddMMM")
        return f.string(from: d)
    }
}
