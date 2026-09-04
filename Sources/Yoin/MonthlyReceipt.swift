import Foundation

/// Identifies the month a listening receipt summarises (used to drive the sheet).
struct ReceiptMonth: Identifiable, Equatable {
    let year: Int
    let month: Int
    var id: Int { year * 100 + month }
    var name: String { "\(SmartRule.monthName(month)) \(year)" }
}

/// Decides when to auto-show the monthly listening receipt — once per month, for the month
/// that just ended, mirroring `WhatsNew.shouldAutoShow()`'s "advance the marker either way"
/// gate. Re-triggering later (from the month's playlist) bypasses this.
enum MonthlyReceipt {
    private static let lastKey = "yoin.lastReceiptMonth"

    static func shouldAutoShow(now: Date = Date(), calendar: Calendar = .current) -> ReceiptMonth? {
        // The receipt covers the *previous* calendar month (shown from the 1st onward).
        guard let prev = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
        let y = calendar.component(.year, from: prev)
        let m = calendar.component(.month, from: prev)
        let key = y * 100 + m

        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastKey) as? Int
        defaults.set(key, forKey: lastKey)                 // advance either way
        guard let last, last != key else { return nil }    // fresh install, or already shown

        // Only worth showing if there was real listening that month.
        let has = HistoryStore.load().contains { e in
            e.isRealListen
                && calendar.component(.year, from: e.date) == y
                && calendar.component(.month, from: e.date) == m
        }
        return has ? ReceiptMonth(year: y, month: m) : nil
    }
}
