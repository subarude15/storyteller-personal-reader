# ink+amp Continue widget — how it works and how to verify it

The Home Screen tile that shows **Now** (the current Continue item: cover, title,
progress) and up to **three Up next** rows from the same Home mixed queue
(books and podcasts, last-touched). Play/pause and ±15s on Now still act
**without opening the app** while a live audio session exists.

- Widget kind: `inkamp.continue.upnext.v1` (`SilveranWidgetConstants.continueWidgetKind`).
  This is a **new** kind. The previous kind `InkAmpContinueWidget` is retired
  (with `inkamp.continue.v3` / `.v4`) and is never reloaded. WidgetKit keeps an
  already-installed tile bound to the old kind, so that tile stays the old
  Continue-only paint even after this build. After install, **remove the old
  Continue tile** and add the new **Continue + Up next** (medium).
- Families: small (Now only) and medium (Now + Up next). Medium is the one to add.
  Lock Screen accessories stay the existing Now glance.
- Background: opaque charcoal `containerBackground` (`#0B0B0C`, `InkAmpWidgetPalette.background`).
  Never `Color.clear`.
- Sources: `SilveranWidgets/Sources/InkAmpContinueWidget.swift` (paint),
  `SilveranKit/Sources/AppleKit/WidgetSupport/ContinueWidget{SnapshotStore,Intents}.swift`
  (shared state + transport), publisher in
  `SilveranKit/Sources/AppleKit/MobileDesktop/ContinueWidgetPublisher.swift`
- Queue: `HomeMixedQueue` in the app. `ContinueWidgetPublisher.publishHomeContinue`
  writes Continue plus the next 3 (`ContinueWidgetSnapshot.upNextLimit`) whenever
  Home republishes: Home appear, a queue-key change, and `punkRallyHomeQueueDidChange`.
  Opening the app (foreground, `scenePhase == .active`) posts that notification,
  so one launch writes `upNext` into the App Group snapshot. There is no second queue.

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
Group container. Now's cover is `ContinueCovers/continue_cover.dat`. Each Up
next row stores id, title, kind, deep link, optional progress, and a cover file
`ContinueCovers/upnext_<hash>.dat` (at most 3).

Now fields: title, subtitle, cover filename, `isPlaying`, kind, deep link,
whole-item progress, elapsed/duration seconds, `hasLiveSession`, rate.

Up next is replaced only when Home publishes a list (including an empty list,
which clears the rows). Live-session ticks pass `upNext: nil` so playback
progress does not wipe the queue. A queue change reloads WidgetKit immediately;
progress ticks stay throttled to one reload per 20s.

While audio is live, the Now card follows that session so play/pause matches
what is actually playing. Up next still comes from `HomeMixedQueue`. With no
live session, Now is the Home Continue item. An empty queue publishes no title
and no Up next — the tile says **Nothing in progress** and does not invent
Ideas or Open Library titles.

Taps:

- Now → `punkrally://continue` (existing host: Now Playing if live, else Home Continue).
- Up next row → `punkrally://continue?item=<HomeMixedItem.id>` (`book:…` or `pod:…`).
  The host opens that row through the same Continue / podcast bridge. No new player.
  Up next does not send transport intents.

## 4. Verifying on device

1. Install the IPA from the `punkrally-sideload-unsigned-ipa` artifact
   (build log should show `==> App Group entitlement present on app + appex`).
2. Open the app once so Home writes Now + Up next into the App Group snapshot.
   Then long-press the Home Screen → **Add Widget** → **Continue + Up next**
   (medium). **Remove the old Continue tile first.** That tile is kind
   `InkAmpContinueWidget` (and older `inkamp.continue.v3` / `.v4`); those kinds
   are retired and never reloaded, so iOS will not repaint them as Now + Up next.
3. Start a book or an episode, then background the app. The **medium** tile
   should show Now (cover, title, progress) and up to three Up next rows
   (thumb + title) from Home. The small tile stays Now only.
4. Play/pause/±15s on Now should act without bringing the app forward while
   audio is live. Tapping Now opens `punkrally://continue`. Tapping an Up next
   row opens that book or episode (same player / podcast bridge as Home).
5. With nothing in progress and nothing playing, the tile says
   "Nothing in progress" — not a made-up title.
6. Console probe (Mac → Window → Devices → Console, filter `ContinueWidget`):

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

## 7. Free AltStore and richer WidgetKit

The layout and the snapshot ship on the same Sideload IPA as the Continue tile.
App Group resolution is unchanged: one group, `ALTAppGroups` first, then
`SILVERAN_WIDGET_APP_GROUP`, then `group.com.punkrally.reader`. Entitlements
still have to be inside the IPA (`scripts/package-ipa` ad-hoc sign + assert) or
AltStore never creates the group.

Free personal teams can still be flaky about WidgetKit itself — timeline
reloads, multi-link taps, and interactive buttons sometimes stall even when the
snapshot on disk is correct. That is a signing/runtime limit, not a second
queue. If the medium tile looks stale or a row tap does nothing:

- Remove the old Continue tile and add **Continue + Up next** (medium). The kind
  is `inkamp.continue.upnext.v1`, not `InkAmpContinueWidget`.
- Confirm the console line shows `resolved=ok` with the team-suffixed group.
- Home Continue and `punkrally://continue` still work without the tile.
  Lock Screen / StandBy are not part of this cut; the existing accessory
  families only glance at Now.
