# ink+amp Continue widget — how it works and how to verify it

The Home Screen / Lock Screen tile that shows what you were last on (cover, title,
progress) with play/pause and ±15s that act **without opening the app**.

- Widget kind: `InkAmpContinueWidget` (`SilveranWidgetConstants.continueWidgetKind`)
- Sources: `SilveranWidgets/Sources/InkAmpContinueWidget.swift` (paint),
  `SilveranKit/Sources/AppleKit/WidgetSupport/ContinueWidget{SnapshotStore,Intents}.swift`
  (shared state + transport), publisher in
  `SilveranKit/Sources/AppleKit/MobileDesktop/ContinueWidgetPublisher.swift`

---

## 1. Why the earlier tile was blank on AltStore

Three separate links in the chain have to hold. The parked version broke the
first and third, which is why the tile painted "blank + tappable".

### (a) Entitlements have to be inside the IPA's binary

`AltSign`/AltStore reads an app's declared capabilities with
`ldid::Entitlements()` over `LC_CODE_SIGNATURE` — i.e. the entitlements blob in
the Mach-O. `scripts/package-ipa` builds with `CODE_SIGNING_ALLOWED=NO`, which
leaves the binary **unsigned and therefore entitlement-less**; AltStore then sees
no `com.apple.security.application-groups`, never creates/assigns a group
(`updateAppGroups` returns early), and the resigned app + widget come out with
no shared container at all.

The script now ad-hoc signs (`codesign --force --sign - --entitlements …`) the
app **and** every `PlugIns/*.appex` before zipping, and then asserts that both
signatures carry `com.apple.security.application-groups =
group.com.punkrally.reader` (`codesign -d --entitlements :-`). Ad-hoc signing is
fine here: it exists purely so AltStore can read the entitlements — AltStore
re-signs everything with the user's own certificate on install.

### (b) AltStore appends the team id to the group

`FetchProvisioningProfilesOperation.updateAppGroups` provisions
`<declared-group>.<TEAMID>` (here `group.com.punkrally.reader.ABCDE12345`,
created as "AltStore group com punkrally reader" if missing) and registers the
right App IDs (`1 + appExtensions.count`, which is why the appex costs an extra
free-team App ID). Then `ResignAppOperation.prepare` writes the granted
identifiers into the Info.plist of the app **and of every embedded appex** under
the key `ALTAppGroups`.

### (c) The app + widget have to read the granted id

The parked build read only `SILVERAN_WIDGET_APP_GROUP`
(`group.com.punkrally.reader`), so `containerURL(forSecurityApplicationGroupIdentifier:)`
returned `nil` on a resigned build: the app published a snapshot nothing could
read. `SilveranWidgetSnapshotStore.appGroupCandidates(bundle:)` now resolves

1. `ALTAppGroups` (the granted, team-suffixed ids — first valid entry),
2. `SILVERAN_WIDGET_APP_GROUP` (Xcode / TestFlight / paid team),
3. `group.com.punkrally.reader` (constant fallback),

skipping empty or unexpanded `$(…)` values and de-duplicating, and
`sharedContainerURL()` walks the candidates until one resolves a container.

## 2. Transport controls that survive backgrounding

Play/pause and ±15s are App Intents conforming to `AudioPlaybackIntent`
(`ContinueWidgetIntents.swift`):

- `AudioPlaybackIntent` makes WidgetKit perform the intent **in the app's
  process** (background launch when the app is suspended) instead of the widget
  extension's sandbox. A plain `AppIntent` in the extension produces the
  device-only failure `ATAudioSessionClientImpl.mm:281 activation failed.
  status = 561015905` — the simulator hides it.
- The intent types must be compiled into **both** the app and the widget
  extension. Both link the `SilveranAppleWidgets` SwiftPM product, so that holds.
- The app already declares `UIBackgroundModes: [audio, fetch]`.
- On iOS 26+ the intents also declare `supportedModes = .background` (the
  replacement for the deprecated `openAppWhenRun`), so a tap never foregrounds
  the app.

After performing, the intent republishes the snapshot from the live session
(`ContinueWidgetSnapshotStore.publishFromLiveSession()`) so play ⇄ pause flips
immediately, then asks WidgetKit to reload.

When there is no live session (cold launch, nothing playing) the snapshot is
marked `hasLiveSession: false` and the tile renders the last item plus a
tap-to-continue deep link instead of a button that would silently do nothing.
Tapping always opens `punkrally://continue` → Now Playing if live, else Home
Continue.

## 3. Payload and write coalescing

`ContinueWidgetSnapshot` is stored as JSON (`continue-now.json`) in the App
Group container, covers as `ContinueCovers/continue_cover.dat`:
title, subtitle, cover filename, `isPlaying`, kind, deep link, whole-item
progress, elapsed/duration seconds, `hasLiveSession`, rate.

The snapshot is only rewritten when something the widget paints changed, and
WidgetKit reloads are throttled to at most one per 20s while playback advances
(immediate on transport changes), so a playing audiobook does not burn the
widget reload budget.

## 4. Verifying on device

1. Install the IPA from the `punkrally-sideload-unsigned-ipa` artifact
   (build log should show `==> App Group entitlement present on app + appex`).
2. Long-press the Home Screen → **Add Widget** → *ink+amp Continue*. Delete any
   old blank tile from the parked build first — the previous kinds
   (`inkamp.continue.v3` / `.v4`) are retired and never reloaded.
3. Start a book or an episode, then background the app. The tile should show
   cover + title + progress, and play/pause/±15s should act without bringing
   the app forward.
4. Console probe (Mac → Window → Devices → Console, filter `ContinueWidget`):

   ```
   [ContinueWidget] publish altGroups=["group.com.punkrally.reader.ABCDE12345"] candidates=[…] resolved=ok
   ```

   The app logs this on every publish and the widget on every timeline load.
   - `altGroups=[]` → AltStore did not see the app group (check the entitlements
     assertion in the build log).
   - `resolved=nil` with a non-empty `altGroups` → the group was not granted for
     this bundle/profile; re-install after refreshing in AltStore.

## 5. What it costs on a free Apple ID

- One extra App ID for the appex (`RequiredAppIDs = 1 + appExtensions.count`)
  plus one App Group, out of the 10-per-7-days budget; the appex also counts
  toward the 3-active-app limit.
- If AltStore reports app-group errors during install (`3014` / `3015`), delete
  an unused sideloaded app and retry.

## 6. Fallbacks that still work without the tile

In-app Home Continue, the `punkrally://continue` deep link (Shortcuts, widgets
from other apps) and the system Lock Screen Now Playing controls are unchanged;
if the appex ever fails to install, nothing else regresses.
