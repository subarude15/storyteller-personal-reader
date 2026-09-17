# ink+amp Continue widget

Home Screen (and Lock Screen accessory) tile that shows what you were last on —
cover art, title, progress — with play/pause and ±15s that work **without
opening the app**.

Kinds: `InkAmpContinueWidget` (`SilveranWidgetConstants.continueWidgetKind`).
The old static placeholders (`inkamp.continue.v3` / `.v4`) are retired; delete
any leftover "ink+amp Continue" tile from the parked build and re-add the widget.

---

## What was broken (2026-09 fix)

The first shipped attempt rendered a blank / "Open ink+amp" card on AltStore.
The App Group *was* being created — the app and the extension were simply
looking for the wrong container:

1. The IPA declares `com.apple.security.application-groups` =
   `group.com.punkrally.reader` (literal, see
   `XCodeApps/SilveranReaderSideload.entitlements` and
   `SilveranReaderWidgets.entitlements`).
2. When AltStore Classic resigns an app it provisions that group for your
   personal team and **appends the signing team identifier**:
   `group.com.punkrally.reader.<TEAMID>`
   (`FetchProvisioningProfilesOperation.updateAppGroups` — it also creates the
   group as "AltStore group com punkrally reader" if it is missing).
3. AltStore then writes the granted identifiers into the Info.plist of the app
   **and of every embedded app extension**, under the key `ALTAppGroups`
   (`ResignAppOperation.prepare`). It also fixes up
   `NSExtensionFileProviderDocumentGroup`.
4. The app + widget only ever read `SILVERAN_WIDGET_APP_GROUP`
   (`group.com.punkrally.reader`), so
   `containerURL(forSecurityApplicationGroupIdentifier:)` returned nil on the
   sideloaded build. The app had nothing it could write where the widget could
   read, and the widget had nothing to paint — hence the blank tiles.

`SilveranWidgetSnapshotStore.appGroupCandidates(bundle:)` now resolves in this
order:

1. `ALTAppGroups` (the identifiers AltStore actually granted, team-suffixed),
2. `SILVERAN_WIDGET_APP_GROUP` (Xcode / TestFlight / paid-team builds),
3. `group.com.punkrally.reader` (constant fallback).

It also filters empty / unexpanded `$(...)` values and de-duplicates, and
`sharedContainerURL()` walks the candidates until one resolves.

## Playback controls

Buttons use App Intents that conform to `AudioPlaybackIntent`:

- `ContinuePlayPauseIntent`, `ContinueSkipBackwardIntent` (−15s),
  `ContinueSkipForwardIntent` (+15s) — all in
  `SilveranKit/Sources/AppleKit/WidgetSupport/ContinueWidgetIntents.swift`.

`AudioPlaybackIntent` makes WidgetKit perform the intent **in the app's
process** (launching it in the background when suspended), so the buttons drive
the same `AudioSessionActor` as the in-app player, CarPlay, and the Lock Screen
controls. Two requirements:

- the intent types must be compiled into **both** the app target and the widget
  extension — both link the `SilveranAppleWidgets` SwiftPM product, so that is
  satisfied by construction;
- the app must declare the `audio` background mode (it does).

After performing, the intent republishes the snapshot from the live session
(`ContinueWidgetSnapshotStore.publishFromLiveSession()`) so the tile flips
play ⇄ pause immediately, then asks WidgetKit to reload.

When there is **no live session** (app relaunched cold, or nothing playing) the
snapshot is marked `hasLiveSession: false` and the tile renders a tap-to-continue
deep link instead of a button that would silently do nothing. Tapping opens
`punkrally://continue` → Now Playing if live, otherwise Home Continue.

## Payload

`ContinueWidgetSnapshot` (App Group file `continue-now.json`, covers in
`ContinueCovers/`): title, subtitle, cover filename, isPlaying, kind, deep link,
progress, elapsed/duration seconds, `hasLiveSession`, rate.

Writes are coalesced: the snapshot is only rewritten when something the widget
paints changed, and WidgetKit reloads are throttled to at most one per 20s while
playback advances (and immediately whenever transport state changes), so a
playing audiobook does not burn the widget reload budget.

## Verifying on device

1. Install the IPA from the `punkrally-sideload-unsigned-ipa` artifact.
2. Long-press the Home Screen → **Add Widget** → *ink+amp Continue*. If the old
   parked tile is still placed, delete it first.
3. Open the app, start a book or episode, then background it. The tile should
   show cover + title + progress, and play/pause/±15s should act without
   bringing the app forward.
4. Console probe (Mac → Window → Devices, or `Console.app` filtered on
   `ContinueWidget`): the app logs
   `[ContinueWidget] publish altGroups=[...] candidates=[...] resolved=ok`
   and the widget logs the same on each timeline load. If `resolved=nil`, the
   App Group was not granted — see SIDELOAD.md troubleshooting.

## Free Apple ID cost

Embedding the extension spends one more App ID (the appex) plus one App Group
from the 10-per-7-days budget, and the extension counts toward the 3-active-app
limit on free accounts. If AltStore reports `(1014)/(3014)/(3015)` app-group
errors during install, remove an unused sideloaded app and retry.
