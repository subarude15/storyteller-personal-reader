import Foundation
import Testing
@testable import SilveranKit

@Suite("Finish tonight / bedtime")
struct BedtimeSettingsTests {
    @Test("Default bedtime is 10:30 PM")
    func defaultMinutes() {
        #expect(BedtimeSettings.defaultMinutesFromMidnight == 22 * 60 + 30)
    }

    @Test("Minutes until bedtime nil after bedtime")
    func pastBedtimeHides() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 23, minute: 0))!
        let minutes = BedtimeSettings.minutesUntilBedtime(
            now: now,
            minutesFromMidnight: 22 * 60 + 30,
            calendar: cal
        )
        #expect(minutes == nil)
    }

    @Test("Minutes until bedtime rounds up")
    func minutesCeil() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // 10:00 → 10:30 = 30m
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 22, minute: 0))!
        let minutes = BedtimeSettings.minutesUntilBedtime(
            now: now,
            minutesFromMidnight: 22 * 60 + 30,
            calendar: cal
        )
        #expect(minutes == 30)
    }

    @Test("Fits when remaining ≤ window")
    func fitsWindow() {
        #expect(BedtimeSettings.fitsTonight(remainingSeconds: 12 * 60, minutesUntilBedtime: 30))
        #expect(BedtimeSettings.fitsTonight(remainingSeconds: 30 * 60, minutesUntilBedtime: 30))
        #expect(!BedtimeSettings.fitsTonight(remainingSeconds: 31 * 60, minutesUntilBedtime: 30))
    }

    @Test("remainingSeconds uses duration × (1 − progress)")
    func remainingSeconds() {
        let left = PlaybackFinishabilityCopy.remainingSeconds(
            progress: 0.5,
            durationSeconds: 3600
        )
        #expect(left == 1800)
        #expect(
            PlaybackFinishabilityCopy.remainingSeconds(progress: 0.96, durationSeconds: 3600)
                == nil
        )
        #expect(
            PlaybackFinishabilityCopy.remainingSeconds(progress: 0.5, durationSeconds: nil) == nil
        )
    }

    @Test("Label still shows Xm left")
    func labelUsesRemaining() {
        let label = PlaybackFinishabilityCopy.label(progress: 0.5, durationSeconds: 24 * 60)
        #expect(label == "12m left")
    }
}
