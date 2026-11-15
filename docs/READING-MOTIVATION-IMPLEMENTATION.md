# Reading motivation v1 implementation

## Scope and defaults

Implemented against `cursor/reading-motivation-v1` at base `08f6c965ce646d8816132ba5ef99f61be5a96f4c`. The checkout was clean before edits and `origin` was `https://github.com/subarude15/storyteller-personal-reader.git`.

This base has no existing daily reading-goal setting in the Swift sources, so v1 starts at 30 minutes per day for reading and 30 minutes per day for listening. Goals accept 5–240 minutes. The local settings record defaults to three Home pins (Read today, This week, Current streak), reminders off, and a 20:30 quiet delivery time. Empty pin selections are supported and shown explicitly. Invalid goal values use the safe defaults; empty/malformed session data contributes zero progress.

Calendar days, week boundaries, quiet delivery, and displayed finish dates use the device's current calendar/time zone. Sessions are split at local midnight. A streak day requires valid recorded session time; the current count may end yesterday until today's activity is recorded. Only sessions being removed by SessionTracker's one-year pruning are archived. Each archived identity freezes its local year/month/day plus source calendar/time-zone identifiers, is never rebucketed after travel, and is deduplicated against live session dates by its calendar-day key. The old v1 absolute-Date cache had no source calendar/time-zone identity and included retained sessions: migration rebuilds overlapping days from available sessions and freezes source-less markers as `legacy-UTC` date identities. Their original local label cannot be recovered without the old time zone; the migration keeps one stable identity per old marker and never rebuckets it again.

## Requirement-to-code/test map

| Requirement | Implementation | Regression coverage |
|---|---|---|
| FR1 — daily reading/listening goals | `XCodeApps/PunkRallyModules/Motivation/ReadingMotivationStore.swift`; editable controls and elapsed/goal meters in `ReadingMotivationSettingsView.swift` and `StatsView.swift`; shared settings normalization in `SilveranKit/Sources/Kit/Stats/ReadingMotivation.swift` | Settings defaults/migration, zero/invalid goal handling, session-derived day totals, NaN duration rejection |
| FR2 — pinned stats | Persistent bounded settings in `ReadingMotivationStore.swift`; selectable pins in `ReadingMotivationSettingsView.swift`; values on Home and Stats in `PunkRallyApp.swift` and `StatsView.swift` | Defaults, duplicate removal, three-item bound; empty selection has an explicit Home/Stats state |
| FR3 — Continue widget | Backward-compatible snapshot calculations and streak field in `ContinueWidgetSnapshotStore.swift`; publication in `ContinueWidgetPublisher.swift`; display in `InkAmpContinueWidget.swift`; ebook duration excluded by `HomeMixedQueue.swift` | Old snapshot decode, elapsed/length, speed-adjusted wall time, invalid/unknown/overshoot values, streak display inputs |
| FR4 — streak records | SessionTracker-derived records and prune-only `ReadingMotivationActivityDay` archive in `SessionTracker.swift`; chronological local-day split, key-based dedupe and current/longest calculations in `ReadingMotivation.swift` | Midnight/DST split, repeated session IDs/imports, travel across date boundaries, legacy-marker migration, pruning idempotence, today/yesterday, longest streak |
| FR5 — projected finish | Continue item progress and real page count/audio duration in `ReadingMotivationStore.swift`, rendered by `PunkRallyApp.swift`; shared pace/speed estimate in `ReadingMotivation.swift` | Observed reading pace, no/zero pace, finished state, unknown duration, playback speed, DST boundary |
| FR6 — weekly receipts | Local calendar-week calculation in `ReadingMotivation.swift`; current/prior receipt UI in `StatsView.swift` | Week rollover split, deterministic week, empty/prior week, title dedupe and activity day count |
| FR7 — local notifications | FIFO async transaction gate serializes coordinator load/reconcile/delivery state in `ReadingMotivation.swift`; injectable scheduler, persisted bounded consumed-day keys, preference/request revisions, and delivery-date attribution; iOS `UNUserNotificationCenter` adapter in `ReadingMotivationNotifications.swift`; opt-in and quiet-time UI in `ReadingMotivationSettingsView.swift`; app/session/foreground/time-zone wiring in `PunkRallyApp.swift`, `SessionTracker.swift`, and `ReadingMotivationStore.swift` | Suspended fake scheduler/state store tests cover concurrent first load, opt-out, competing priorities, delivery during scheduling and scheduling failure; additional tests cover yesterday delivery, historical taps, clock jump/back, bounded history, quiet-time changes, same-kind reschedule, and legacy ledger decode |
| FR8 — shared regression tests | `SilveranKit/Tests/SilveranTests/ReadingMotivationTests.swift`; tests exercise the same SilveranKit calculations and notification coordinator used by the app/widgets | Public day initializer, settings/ledger migration, snapshot compatibility, duration/progress clamping, NaN/unknown values, streak timestamp validity, DST finish boundary, timezone-safe archive, receipts, finish estimates and scheduler serialization |

Correction-pass regression names include `dailySummaryHasPublicValidatedInitializer`, `concurrentFirstTransactionsLoadLedgerOnlyOnce`, `concurrentOptOutWinsAfterSuspendedScheduleAndRejectsStaleRefresh`, `concurrentPriorityTransactionsLeaveHighestPriorityInstalled`, `deliveryDuringSuspendedScheduleConsumesThatDayAndCancelsIt`, `scheduleFailureClearsPendingStateAndAllowsRetry`, `deliveredYesterdayDoesNotConsumeTodayAndOldTapUsesDeliveryDate`, `consumedDayHistorySurvivesJumpForwardAndBack`, `quietTimeChangeReschedulesSameKindAndKeepsHigherPriority`, `archivedLocalDayDoesNotRebucketAcrossTravelDayBoundary`, `archivedActivityDayKeysRemainConsecutiveAcrossDSTAndRepeatedImports`, `pruneDoesNotPersistTwoIdentitiesForSameCalendarDayAfterTravel`, `archivedDaysAreAddedOnlyForExpiredSessionsAndRepeatedPrunesAreIdempotent`, and `sourceLessLegacyMarkerKeepsStableUTCIdentityAfterTravel`.

## Verification

- `git diff --check` — passed for the correction pass.
- `python -c 'import subprocess; status=subprocess.check_output(["git","status","--porcelain=v1"],text=True); forbidden=("tools/native-scroll/","home-scroll-geometry.yml","GlobalMiniPlayerBar.swift","PunkRallyShellSupport.swift","iOSSilveranReaderApp.swift","PlayerPresenter.swift","AudioSessionActor.swift"); assert not any(item in status for item in forbidden); print("PASS: protected-file isolation")'` — `PASS: protected-file isolation`.
- `python -c 'from pathlib import Path; files=[Path("SilveranKit/Sources/Kit/Stats/ReadingMotivation.swift"),Path("SilveranKit/Sources/AppleKit/WidgetSupport/ContinueWidgetSnapshotStore.swift"),Path("XCodeApps/PunkRallyApp.swift"),Path("XCodeApps/PunkRallyModules/Stats/SessionTracker.swift"),Path("SilveranKit/Tests/SilveranTests/ReadingMotivationTests.swift")]; assert not any(chr(92)*2+"(" in line for file in files for line in file.read_text(encoding="utf-8").splitlines()); print("PASS: Swift interpolation source check")'` — `PASS: Swift interpolation source check`.
- `python -c 'from pathlib import Path; text=Path(".github/workflows/reading-motivation-tests.yml").read_text(); assert all(item in text for item in ("runs-on: macos-15","submodules: recursive","./scripts/test","if: always()")); print("PASS: test workflow wiring")'` — `PASS: test workflow wiring`.
- `./scripts/test` — could not execute Swift tests on this Windows host: `./scripts/test: line 8: swift: command not found`. No local Swift RED/GREEN, Xcode build, simulator, or device result is claimed.
- `.github/workflows/reading-motivation-tests.yml` adds the `macos-15` SwiftPM test job using the repository's existing Xcode selection fallback and `./scripts/test`; it retains the test log artifact on failure. CI was not dispatched and remains pending parent review/push.

## Native behavior not verified here

The iOS Swift compile, WidgetKit rendering/reload behavior, App Group sharing on signed and sideload builds, notification authorization/delivery/cancellation, and Home/Stats interaction require macOS CI and device testing. New concurrency and archive migration regressions are authored but unrun locally. The workflow is intended to provide Swift package regression results; the existing `ios.yml` remains the app/widget build gate.

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
