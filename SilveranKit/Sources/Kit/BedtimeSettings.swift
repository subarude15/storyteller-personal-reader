import Foundation

/// Local-only bedtime for Home “Finish tonight”. No server, iCloud, or notifications.
public enum BedtimeSettings {
    public static let minutesFromMidnightKey = "inkamp.bedtime.minutesFromMidnight"
    /// Default 10:30 PM local.
    public static let defaultMinutesFromMidnight = 22 * 60 + 30

    public static var minutesFromMidnight: Int {
        get {
            guard UserDefaults.standard.object(forKey: minutesFromMidnightKey) != nil else {
                return defaultMinutesFromMidnight
            }
            return UserDefaults.standard.integer(forKey: minutesFromMidnightKey)
        }
        set {
            let clamped = max(0, min(23 * 60 + 59, newValue))
            UserDefaults.standard.set(clamped, forKey: minutesFromMidnightKey)
        }
    }

    /// Minutes until today’s bedtime, or `nil` when bedtime has already passed (hide the card).
    public static func minutesUntilBedtime(
        now: Date = Date(),
        minutesFromMidnight: Int = minutesFromMidnight,
        calendar: Calendar = .current
    ) -> Int? {
        let hour = minutesFromMidnight / 60
        let minute = minutesFromMidnight % 60
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        guard let bedtime = calendar.date(from: parts) else { return nil }
        let seconds = bedtime.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return max(1, Int(ceil(seconds / 60.0)))
    }

    public static func date(fromMinutesFromMidnight minutes: Int, calendar: Calendar = .current)
        -> Date
    {
        let hour = minutes / 60
        let minute = minutes % 60
        var parts = calendar.dateComponents([.year, .month, .day], from: Date())
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        return calendar.date(from: parts) ?? Date()
    }

    public static func minutesFromMidnight(from date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// True when remaining play/read time fits in the minutes left before bedtime.
    public static func fitsTonight(
        remainingSeconds: TimeInterval,
        minutesUntilBedtime: Int
    ) -> Bool {
        remainingSeconds <= TimeInterval(minutesUntilBedtime) * 60
    }
}
