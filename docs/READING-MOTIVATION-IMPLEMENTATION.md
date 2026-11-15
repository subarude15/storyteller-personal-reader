# Reading motivation v1 implementation

## Scope and defaults

Implemented against `cursor/reading-motivation-v1` at base `08f6c965ce646d8816132ba5ef99f61be5a96f4c`. The checkout was clean before edits and `origin` was `https://github.com/subarude15/storyteller-personal-reader.git`.

This base has no existing daily reading-goal setting in the Swift sources, so v1 starts at 30 minutes per day for reading and 30 minutes per day for listening. Goals accept 5–240 minutes. The local settings record defaults to three Home pins (Read today, This week, Current streak), reminders off, and a 20:30 quiet delivery time. Empty pin selections are supported and shown explicitly. Invalid goal values use the safe defaults; empty/malformed session data contributes zero progress.

Calendar days, week boundaries, quiet delivery, and displayed finish dates use the device's current calendar/time zone. Sessions are split at local midnight. A streak day requires valid recorded session time; the current count may end yesterday until today's activity is recorded. Only sessions being removed by SessionTracker's one-year pruning are archived. Each archived identity freezes its local year/month/day plus source calendar/time-zone identifiers, is never rebucketed after travel, and is deduplicated against live session dates by its calendar-day key. The old v1 absolute-Date cache had no source calendar/time-zone identity and included retained sessions: migration rebuilds overlapping days from available sessions and freezes source-less markers as `legacy-UTC` date identities. Their original local label cannot be recovered without the old time zone; the migration keeps one stable identity per old marker and never rebuckets it again.

Historical streak references (for example prior-week Sunday night) clip sessions that start before the reference and end after it, keeping the valid earlier portion. Wholly future sessions at real-now remain rejected.

Quiet-time pace/rescue candidates are evaluated against quiet-delivery expectations using current progress, so a morning launch can schedule tonight's reminder without later app interaction. Arbitration uses only currently eligible candidates; an obsolete higher-priority pending kind is replaced or cancelled when progress removes its eligibility.

Continue widget snapshots store `streakActivityDayKey` with the streak count. Audio-only publishes preserve that activity anchor; display resolves today/yesterday grace and expires older streaks. Timelines include a local day-boundary entry so streak text refreshes even when Home never republishes.

`projectedFinish` guards the rounded-up second count against the first Int-unrepresentable bound (`2^63`) before conversion, so `Double(Int.max)` cannot trap.

## Requirement-to-code/test map

| Requirement | Implementation | Regression coverage |
|---|---|---|
| FR1 — daily reading/listening goals | `XCodeApps/PunkRallyModules/Motivation/ReadingMotivationStore.swift`; editable controls and elapsed/goal meters in `ReadingMotivationSettingsView.swift` and `StatsView.swift`; shared settings normalization in `SilveranKit/Sources/Kit/Stats/ReadingMotivation.swift` | Settings defaults/migration, zero/invalid goal handling, session-derived day totals, NaN duration rejection |
| FR2 — pinned stats | Persistent bounded settings in `ReadingMotivationStore.swift`; selectable pins in `ReadingMotivationSettingsView.swift`; values on Home and Stats in `PunkRallyApp.swift` and `StatsView.swift` | Defaults, duplicate removal, three-item bound; empty selection has an explicit Home/Stats state |
| FR3 — Continue widget | Backward-compatible snapshot calculations and dated streak fields in `ContinueWidgetSnapshotStore.swift`; publication in `ContinueWidgetPublisher.swift`; day-boundary resolve in `InkAmpContinueWidget.swift`; ebook duration excluded by `HomeMixedQueue.swift` | Old snapshot decode, elapsed/length, speed-adjusted wall time, invalid/unknown/overshoot values, streak expiry/grace/DST/audio-anchor preservation |
| FR4 — streak records | SessionTracker-derived records and prune-only `ReadingMotivationActivityDay` archive in `SessionTracker.swift`; chronological local-day split, key-based dedupe, clipped historical normalization and current/longest calculations in `ReadingMotivation.swift` | Midnight/DST split, repeated session IDs/imports, travel across date boundaries, legacy-marker migration, pruning idempotence, today/yesterday, longest streak, Sunday→Monday receipt streak clip |
| FR5 — projected finish | Continue item progress and real page count/audio duration in `ReadingMotivationStore.swift`, rendered by `PunkRallyApp.swift`; shared pace/speed estimate in `ReadingMotivation.swift` | Observed reading pace, no/zero pace, finished state, unknown duration, playback speed, DST boundary, Int.max/adjacent/extreme pace guards |
| FR6 — weekly receipts | Local calendar-week calculation in `ReadingMotivation.swift`; current/prior receipt UI in `StatsView.swift` | Week rollover split, deterministic week, empty/prior week, title dedupe, prior-week streak consistency with totals |
| FR7 — local notifications | FIFO async transaction gate serializes coordinator load/reconcile/delivery state in `ReadingMotivation.swift`; injectable scheduler, persisted bounded consumed-day keys, preference/request revisions, and delivery-date attribution; proactive quiet-time candidate construction; iOS `UNUserNotificationCenter` adapter in `ReadingMotivationNotifications.swift`; opt-in and quiet-time UI in `ReadingMotivationSettingsView.swift`; app/session/foreground/time-zone wiring in `PunkRallyApp.swift`, `SessionTracker.swift`, and `ReadingMotivationStore.swift` | Suspended fake scheduler/state store tests cover concurrent first load, opt-out, competing priorities, delivery during scheduling and scheduling failure; morning launch → quiet-time schedule without further interaction; goal-met cancel; obsolete rescue yielding to pace; yesterday delivery, historical taps, clock jump/back, bounded history, quiet-time changes, same-kind reschedule, and legacy ledger decode |
| FR8 — shared regression tests | `SilveranKit/Tests/SilveranTests/ReadingMotivationTests.swift`; tests exercise the same SilveranKit calculations and notification coordinator used by the app/widgets | Public day initializer, settings/ledger migration, snapshot compatibility, duration/progress clamping, NaN/unknown values, streak timestamp validity, DST finish boundary, timezone-safe archive, receipts, finish estimates and scheduler serialization |

Correction-pass regression names include `dailySummaryHasPublicValidatedInitializer`, `concurrentFirstTransactionsLoadLedgerOnlyOnce`, `concurrentOptOutWinsAfterSuspendedScheduleAndRejectsStaleRefresh`, `concurrentPriorityTransactionsLeaveHighestPriorityInstalled`, `deliveryDuringSuspendedScheduleConsumesThatDayAndCancelsIt`, `scheduleFailureClearsPendingStateAndAllowsRetry`, `deliveredYesterdayDoesNotConsumeTodayAndOldTapUsesDeliveryDate`, `consumedDayHistorySurvivesJumpForwardAndBack`, `quietTimeChangeReschedulesSameKindAndKeepsHigherPriority`, `archivedLocalDayDoesNotRebucketAcrossTravelDayBoundary`, `archivedActivityDayKeysRemainConsecutiveAcrossDSTAndRepeatedImports`, `pruneDoesNotPersistTwoIdentitiesForSameCalendarDayAfterTravel`, `archivedDaysAreAddedOnlyForExpiredSessionsAndRepeatedPrunesAreIdempotent`, and `sourceLessLegacyMarkerKeepsStableUTCIdentityAfterTravel`.

Fix-pass-2 regression names include `priorWeekReceiptStreakClipsSundayToMondaySessionAtWeekEnd`, `morningLaunchSchedulesQuietTimeCandidateWithoutFurtherInteraction`, `obsoleteRescueEligibilityYieldsToCurrentPaceCandidate`, `widgetStreakExpiresOnDayRolloverWithTodayYesterdayGrace`, and `projectedFinishRejectsIntMaxRoundingTrapAndExtremePace`.

## Verification

- `git diff --check` — passed for fix-pass-2.
- Protected-file isolation check — `PASS: protected-file isolation`.
- Swift interpolation source check — `PASS: Swift interpolation source check`.
- Test workflow wiring check — `PASS: test workflow wiring` (explicit `shell: bash`, `set -euo pipefail`, `permissions: contents: read`, `if: always()` artifact retain).
- Local pipefail negative check — `bash -c 'set -euo pipefail; false | tee /tmp/rm-pipefail.log'; echo exit:$?'` → nonzero exit (failure propagates; does not look green).
- `./scripts/test` — could not execute Swift tests on this Windows host: `swift: command not found`. No local Swift RED/GREEN, Xcode build, simulator, or device result is claimed.
- `.github/workflows/reading-motivation-tests.yml` remains a test-only `macos-15` SwiftPM job; CI was not dispatched and remains pending parent review/push.

## Native behavior not verified here

The iOS Swift compile, WidgetKit rendering/reload behavior, App Group sharing on signed and sideload builds, notification authorization/delivery/cancellation, and Home/Stats interaction require macOS CI and device testing. New fix-pass-2 regressions are authored but unrun locally. The workflow is intended to provide Swift package regression results; the existing `ios.yml` remains the app/widget build gate.

## Integration review overlaps

The shipping geometry branch has substantially diverged Home/Stats surfaces. Reconcile these task changes deliberately against that branch before integration, especially:

- `XCodeApps/PunkRallyApp.swift`
- `XCodeApps/PunkRallyModules/Home/HomeMixedQueue.swift`
- `XCodeApps/PunkRallyModules/Stats/SessionTracker.swift`
- `XCodeApps/PunkRallyModules/Stats/StatsView.swift`
- `SilveranKit/Sources/AppleKit/MobileDesktop/ContinueWidgetPublisher.swift`
- `SilveranKit/Sources/AppleKit/WidgetSupport/ContinueWidgetSnapshotStore.swift`
- `SilveranWidgets/Sources/InkAmpContinueWidget.swift`

No geometry harness, inset/safe-area/player-reservation, player host, signing, entitlement, bundle-ID, or App Group identity files were changed.
