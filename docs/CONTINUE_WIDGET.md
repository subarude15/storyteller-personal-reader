# ink+amp Continue + Next Up widgets — how they work and how to verify

Four Home Screen tiles that show **Now** (current Continue item: cover, title,
progress) and **Up Next** from the same Home mixed queue, plus Continue / Browse
Queue actions. Playback transport controls are **not** on these tiles.

## Widget kinds

| Gallery name | Kind | Family |
|---|---|---|
| ink+amp Light Medium | `inkamp.continue.light.medium.v1` | `.systemMedium` |
| ink+amp Light Large | `inkamp.continue.light.large.v1` | `.systemLarge` |
| ink+amp Dark Medium | `inkamp.continue.dark.medium.v1` | `.systemMedium` |
| ink+amp Dark Large | `inkamp.continue.dark.large.v1` | `.systemLarge` |

Constants: `SilveranWidgetConstants.continueWidgetKinds`. Snapshot publish reloads
**all four** kinds via `ContinueWidgetSnapshotStore.reloadTimelines()`.

### Retired kinds (do not reinstall)

These must never be registered or reloaded again — WidgetKit keeps a Home Screen
instance bound to its kind, so a stale/blank tile will not pick up the new layout:

- `InkAmpContinueWidget`
- `inkamp.continue.v3` / `inkamp.continue.v4`
- `inkamp.continue.upnext.v1`

**After installing a new build:** remove any old Continue / Continue + Up next
tile from the Home Screen, open ink+amp once (so the App Group snapshot is
written), then add one of the four new widgets.

## Design (Concept 2)

- **Medium:** Now (cover, NOW label, title, subtitle, progress + caption) | Up
  Next (2 rows) | bottom Continue + Browse Queue.
- **Large:** larger Now | Up Next (3 rows) | large Continue + Browse Queue.
- No play/pause, skip, or `AudioPlaybackIntent` buttons on the Home Screen tiles.
  Transport intents may still exist in shared code for other surfaces.

### Light palette

| Role | Hex |
|---|---|
| Background (Blanc) | `#FFFFFF` |
| Accent / NOW (Aqua) | `#95D9C0` |
| Progress + Continue (Carmin) | `#D41F26` |
| Browse Queue | light translucent surface, dark text |

Aqua is framing/accent only — the whole tile is not aqua.

### Dark palette

| Role | Hex |
|---|---|
| Background (Sea Grey) | `#363636` |
| Accent / progress / Continue (Tangerine) | `#F58F20` |
| Browse Queue (Leaf Green) | `#467434` |

## Interactions

| Action | Link |
|---|---|
| Continue | `snapshot.deepLink` when set, else `punkrally://continue` |
| Up Next row | that row’s `ContinueWidgetQueueItem.deepLink` |
| Browse Queue / Open ink+amp | `punkrally://home` → Home tab (queue view) |

## Data

Single source of truth: `ContinueWidgetSnapshot` in the App Group (same
`ContinueWidgetSnapshotStore` / `ContinueWidgetPublisher` / Home mixed queue).
There is no second Up Next queue. The widget does not query Storyteller.

## Empty state

If there is no current item, the tile shows a polished empty card (not blank):

- Light: Blanc + Aqua accent + Carmin “Open ink+amp”
- Dark: Sea Grey + Tangerine accent

Copy: “Nothing in progress” / “Start a book or podcast in ink+amp.”

## App Group / AltStore (unchanged)

Resolution order is still:

1. `ALTAppGroups` (team-suffixed ids from AltStore resign)
2. `SILVERAN_WIDGET_APP_GROUP`
3. `group.com.punkrally.reader`

`SilveranWidgetSnapshotStore.sharedContainerURL()` walks candidates until one
resolves. App + widget extension entitlements and `scripts/package-ipa`
entitlement assertions are unchanged.

Console probe (filter `ContinueWidget`):

```
[ContinueWidget] publish altGroups=["group.com.punkrally.reader.ABCDE12345"] candidates=[…] resolved=ok
```

## Sources

- Paint: `SilveranWidgets/Sources/InkAmpContinueWidget.swift`
- Theme / actions: `SilveranKit/.../WidgetSupport/InkAmpContinueWidgetTheme.swift`
- Snapshot + links: `ContinueWidgetSnapshotStore.swift`
- Publisher: `ContinueWidgetPublisher.swift`
- Bundle ID stays `com.punkrally.reader`

## Verify on device

1. Install the sideload IPA (build log should show App Group entitlement on app + appex).
2. Delete any old blank / Continue + Up next tile.
3. Open ink+amp once, start a book or podcast, background the app.
4. Add Widget → pick one of the four **ink+amp** Light/Dark Medium/Large tiles.
5. Tap Continue, an Up Next row, and Browse Queue — each should open the right place.
