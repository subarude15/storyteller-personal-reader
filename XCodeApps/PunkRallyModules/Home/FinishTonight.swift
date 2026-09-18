//
//  FinishTonight.swift
//  ink+amp
//
//  Home “Finish tonight” picks — in-progress items that fit the bedtime window.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit

public enum FinishTonight {
    /// Up to `limit` Continue / in-progress items whose remaining time fits tonight’s window.
    public static func picks(
        from items: [HomeMixedItem],
        minutesUntilBedtime: Int,
        limit: Int = 3
    ) -> [HomeMixedItem] {
        guard minutesUntilBedtime > 0, limit > 0 else { return [] }
        var result: [HomeMixedItem] = []
        for item in items {
            guard
                let remaining = PlaybackFinishabilityCopy.remainingSeconds(
                    progress: item.progress,
                    durationSeconds: item.durationSeconds
                ),
                BedtimeSettings.fitsTonight(
                    remainingSeconds: remaining,
                    minutesUntilBedtime: minutesUntilBedtime
                )
            else { continue }
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    public static func header(minutesUntilBedtime: Int) -> String {
        "You’ve got ~\(minutesUntilBedtime)m before bedtime."
    }
}
