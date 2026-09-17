# ink+amp — roadmap

Living board for Cursor, Hermes, and the Grok crew. **Update this file when tips/IPAs land** so agents follow current Now items — not stale Keychain / “wire shared player” work.

| | |
|---|---|
| **Repo** | https://github.com/subarude15/storyteller-personal-reader |
| **Branch** | `punk-rally-ios` |
| **Bundle ID** | `com.punkrally.reader` (do not change) |
| **NUC workspace** | `C:\Users\imalo\dev\silveran-ios\silveran-reader` |
| **Docs beside repo** | `C:\Users\imalo\dev\silveran-ios\` (`PODCASTS-SHELF-PRUNE.md`, `UX-SHELL.md`, `UX-BACKLOG.md`, `DESIGN.md`) |
| **Policy in repo** | `PODCASTS-SHELF-PRUNE.md` |

**Product gate (proven 2026-09-15):** Storyteller place sync phone ↔ iPad — same spot after listen/read. That is the core reason for ink+amp.

---

## Now (do first)

- **No active committed cut** — soft UX polish pack is complete; await Josh smoke / board reorder.

**Do not start DSM/SMB dump, CarPlay, widgets, Story Timeline, Finish tonight, Wrapped, series strip, Shortcuts, or a second player unless Josh reorders.**
## Shipped

### Product / sync
- [x] Storyteller Cloudflare Access Google bypass (server)
- [x] Storyteller URL **prefill** (not auto-save)
- [x] Keychain Save on AltStore (drop Data Protection / no `KEYCHAIN_ACCESS_GROUP` on Sideload) — verified
- [x] Library/Shelf: undownloaded tap → book detail (`84a07a7`); downloaded open path
- [x] Dead-tap fix for downloaded titles (`fde181c`)
- [x] **Phone ↔ iPad place sync proven** (Continue + Synced chip)
- [x] **One-tap LAN failover** — tip `4f9d27d` (not docs `1294bae`); optional LAN URL on Storyteller source (default `http://192.168.1.2:1800`); Using LAN / Using public; Josh confirmed Sideload [35162431083](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35162431083)

### Shell / branding
- [x] M1 shell: Home · Library · Shelf · Podcasts · Stats
- [x] Shelf downloads-only + mini-player
- [x] Home Continue + sync chip (PR 4 / `937ef9a`)
- [x] **Home mixed Continue / Up next** — books + podcasts one rail; last-touched sort shipped (`be1b3ca`, Sideload [35003191824](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35003191824)); Josh confirmed Vergecast Continue + POD
- [x] ink+amp display name + twin-pages AppIcon (keep `com.punkrally.reader`)
- [x] Settings half of PR 6
- [x] CI: Builtin/StoryAlign / Xcode pin / Sideload unsigned IPA pipeline
- [x] **Build identity stamp** — Settings → Build `MMDDYY.HHmm` America/New_York (`scripts/stamp-build`); Josh saw `091526.1345`
### Podcasts
- [x] Shared Now Playing + playback speed (`66fadcd` + `3639b67`) — Josh smoke-tested / shipped (one `PlaybackRateButton`)
- [x] Shelf auto-prune for RSS downloads (`81cd134`) — Sideload **green**
- [x] Audio | Video episode sheet (`e2e0de0` + `6cc51ba`) — Sideload green [Actions 34990644848](https://github.com/subarude15/storyteller-personal-reader/actions/runs/34990644848)
- [x] **Podcast playhead resume** — `PodcastPlayheadStore`; seek on `openPodcast` (`be395da`); Josh confirmed
- [x] **Find shows** — Apple iTunes Search API → Subscribe → `PodcastSubscriptionStore` (`a0fc4e4`, Sideload [35013733091](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35013733091)); Josh confirmed
- [x] **Ad-strip download / queue UX (v1 = UX + hooks + stub)** — tip `130c877` (prior `60a211b` / `c93deac`); Download sheet Original vs Clean (per-show last choice); Keep/queue → Clean pending; chips Original | Cleaning… | Clean; `StubPodcastAdStripPipeline`; Sideload green [35019916837](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35019916837)
- [x] **NAS `AD_STRIP_URL` full cut (option 2)** — tip `e00d800`; Settings **Ad strip URL** + **Test**; dumb ffmpeg worker `:20129`; upload Original → poll → Clean sibling (never delete Original); Josh confirmed Clean ad-free (`e00d800` + `:20129`); Sideload green [35038255753](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35038255753)
- [x] **Silence-trim on NAS AD_STRIP** — tip `d8af263`; leading+trailing edge trim in Clean dumb pipeline; Josh verified health + job JSON on PrincessDonut `:20129`
- [x] **Hybrid RSS video + Watch on YouTube** — tip `87b56cd`; video surface in full Now Playing for dual enclosures; Watch on YouTube chip (episode sheet + full NP, not mini); Sideload green; Josh confirmed
- [x] **YouTube extract video-id only** — tip `cca28ec`; chips only when feed has real watch URL (channel/@handle skipped)
- [x] **Match on YouTube** — tip `a0722eb`; Josh confirmed Match → confirm → Play in ink+amp (Invidious `http://192.168.1.2:20130`)
- [x] **YouTube playhead persist (local)** — Josh confirmed scrub/leave/reopen resumes near leave point
- [x] **YouTube playhead sync** — tip `0a4da30`; private Storyteller blob; Josh confirmed phone↔iPad resume near leave point; Sideload [35164207619](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35164207619)
- [x] **Podcast / player UX polish (stamps 1–5)** — tip `ba4a83d`; pre-subscribe desc; Unsubscribe left / Done right; back→GlobalMiniPlayerBar; scrub seeks YouTube/RSS; iPad NP video fills frame; Josh confirmed; Sideload [35166993973](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35166993973)
- [x] **Browse podcasts (Apple charts/genres)** — tip `ae3990d`; Find empty → Top charts + genre chips + cover grid; tap → pre-subscribe show page; Josh confirmed; Sideload [35168353054](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35168353054)
- [x] **Phone import → StoryAlign read-aloud** — tip `05f0006`; Library Import → EPUB+audio upload → Aligning… / Storyteller queue; Josh confirmed upload; Sideload [35170255405](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35170255405)
- [x] **P0 Mini player inset / close** — tip `bf8bb81` (prior `833d573`); Josh confirmed close/stop with mini up; Sideload [35173181356](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35173181356)
- [x] **SponsorBlock-style skip (in-app YouTube)** — tip `c38b1e4` / feat `2687e9e`; Josh confirmed auto-skip; Sideload green [35174296885](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35174296885)
- [x] **Podcast cross-device sync (subs + playheads)** — tip `51563cd`; Storyteller blob `.inkamp.podcastSync.v1`; LWW subscriptions + episode playheads; downloads stay per-device; Settings last-sync / Offline; Sideload green [35174795554](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35174795554)
- [x] **Glance / system Now Playing** — tip `257e44e`; Josh confirmed Lock Screen / Control Center title + pause/skip
- [x] **Episode status cluster + show filters + Josh UI stamps** — tip `b719921`; download glyph · Clean chip (incl. Clean failed) · Xm left/Played; show filters All|Downloaded|In progress|Clean pending; Shelf POD chrome; mini-player cover+title+play/pause(+close) only (scrub/−15/+15 stay on full Now Playing); Home/Library finishability text via `PlaybackFinishabilityCopy`; Sideload green [35023934089](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35023934089)
- [x] **Podcast play queue** — tip `2f7deb4`; Play Next / Play Last in episode menus; `PodcastPlaybackQueueStore` + editable `PodcastPlaybackQueueView` (drag reorder, remove, clear finished); auto-advance on finish via shared player; persisted upcoming order; Sideload green [35025614228](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35025614228)
- [x] **P0 Podcast resume / Home Continue stall** — tip `7eb0a9e`; Josh confirmed; Loading until playhead advances; Pause only when truly playing; Sideload green [35031138576](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35031138576)

### Shell polish
- [x] **Mini-player above tab bar** — per-tab inset (`be395da`, Sideload [35008731469](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35008731469)); Josh confirmed
- [x] **Mini / full player polish** — −15/+15, elapsed|scrub|remaining, podcast cover on mini (`b8c85f9` / tip ≥ `70866b7`, Sideload [35011914260](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35011914260)); Josh ready for next
- [x] **Mini-player slim** — scrub + −15/+15 removed from mini (status-cluster cut)

### Widgets
- [x] **Continue home widget** — **Re-enabled for Sideload (2026-09)**. The blank-tile bug was a hard-coded App Group id: AltStore grants `<group>.<TEAMID>`, and the app/widget now read `ALTAppGroups` first (`SilveranWidgetSnapshotStore.appGroupCandidates`). Extension re-embedded in the Sideload IPA, kind `InkAmpContinueWidget`: cover + title + progress, play/pause and ±15s through `AudioPlaybackIntent`s that run in the app's process. Write-up: `docs/CONTINUE_WIDGET.md`; SIDELOAD.md notes what it costs against the free App ID budget.
### Stats
- [x] **SessionTracker local** — ebook / audiobook / readaloud / podcast → Home + Stats tab (`c627bbe`, Sideload [35006016694](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35006016694))
- [x] **Cross-device Stats sync** — tip `c5791ec` (`a5226d6` + BookServiceActor fix); private Storyteller collection `.inkamp.stats.v1` blob (same auth as place sync); session-id LWW merge (no double-count / no drop); footer Synced / Syncing… / Offline · local only; Settings last sync time; Sideload green [35028364424](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35028364424)
- [x] **Stats Retry sync** — tip `fdb5560`; Settings last-sync row + Stats footer tappable → Syncing… then Synced / Offline · local only; soft overall + per-step timeouts; Sideload green [35033759537](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35033759537)
- [x] **Stats push / description decode** — tip ``cf5c663``; Josh confirmed syncing; tolerate collection ``description`` objects (String or dict); isolate stats blob; ``pushed=false`` reason log; fail toast; Sideload green [35035504839](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35035504839)

---

## Next (strict order — do not reorder)

### After soft UX polish
1. No committed cut — wait for Josh / board reorder

### Soft UX polish (anytime)
- ~~Mini player inset / close~~ → **Shipped** (`833d573` / `bf8bb81`)
- ~~SponsorBlock-style skip~~ → **Shipped** (`c38b1e4`)
- ~~Podcast cross-device sync~~ → **Shipped** (`51563cd`)
- ~~Stats Retry sync~~ → **Shipped** (`fdb5560`)
- ~~Stats push / description decode~~ → **Shipped** (`cf5c663`) — Josh confirmed
- ~~Soft UX polish pack~~ → **Shipped** (`codex/soft-ux-polish-pack`): Cleaning job chip stays separate from episode time-left; Play shows Resolving… and never auto-hands off; dark cover placeholders across Home/Library/Find/queue; Aligning… / Creating Readaloud… stays distinct from device SYNC; Storyteller/Stats/Find empty and offline states expose clear next actions.
- Separate **Couldn't save server** copy (≠ “Connection failed”) — still soft / not part of the closed pack

---
## Later / ideas (not blocking)

Strict order (Smokey / Nas-ty):
1. ~~NAS `AD_STRIP_URL` worker~~ → **Shipped** (`e00d800` + `:20129`)
2. ~~Silence-trim~~ → **Shipped** (`d8af263`; Josh verified)
3. ~~Full in-app YouTube embed/SDK~~ → **superseded** by hybrid + in-app YouTube v1 + Match
4. ~~Match on YouTube~~ → **Shipped** (`a0722eb`; Josh confirmed)
5. ~~YouTube playhead persist (local)~~ → **Shipped** (Josh confirmed resume)
6. ~~Glance / Lock Screen~~ → **Shipped** (`257e44e`; Josh confirmed)
7. ~~LAN failover~~ → **Shipped** (`4f9d27d`; Josh confirmed Using LAN / Using public)
8. ~~YouTube playhead sync~~ → **Shipped** (`0a4da30`; Josh confirmed)
9. ~~Browse podcasts (Apple charts/genres)~~ → **Shipped** (`ae3990d`; Josh confirmed)
10. ~~SponsorBlock-style skip~~ → **Shipped** (Josh confirmed; tip `c38b1e4`)
11. ~~Phone import → StoryAlign read-aloud~~ → **Shipped** (`05f0006`; Josh upload OK)
12. ~~Podcast cross-device sync~~ → **Shipped** (`51563cd`; subs + playheads; downloads per-device)
13. ~~CarPlay~~ → **parked** (Josh: already does what he needs on free AltStore); Apple Watch remains out of Sideload scope

**Cancelled (Josh 2026-09-16):** DSM/SMB/WebDAV folder dump — happy with Storyteller Import as-is.

**Later toys (only if reordered):** Story Timeline; Finish tonight; Wrapped/heat map; series strip; Shortcuts Continue; widgets; second player.
## Constraints

- Keep `SilveranKit`; do not merge Enve tree (modules + AGPL only)
- Storyteller = ebook / audiobook / readaloud; podcasts = RSS rail
- AltStore unsigned IPA; no Apple Developer until we choose to
- No Expo; no Xcode on JoshNuc — GitHub Actions macOS for builds
- Sideload: never reintroduce `KEYCHAIN_ACCESS_GROUP`
- Agents: do **not** treat Actions run numbers (#57/#58/#59) as GitHub issue tickets
- Heavy coding: Hermes / Cursor via OmniRoute free-first (`deepseek/deepseek-v4-pro` preferred); Grok Bot cloud usage may be exhausted

---

## Cursor / Hermes standing brief

When picking up work:
1. `git pull` on `punk-rally-ios` — tip must match **Now** above
2. Read this `ROADMAP.md` + the listed policy/UX docs
3. Implement **only** the top unchecked Now/Next item
4. Open a focused PR; leave Sideload CI green (`punkrally-sideload-unsigned-ipa`)
5. Update this file: move Done → Shipped; promote Next → Now

**Ping Josh in the crew room whenever a new Sideload IPA is green to install.**

---

## Owners

| Area | Owner |
|------|--------|
| Storyteller / NAS / Cloudflare / CI watch | Nas-ty Girl |
| UX shell / Stitch / prune explainer / A\|V sheet | Ui And Design |
| App code / PRs / IPA | Smokey Coding + Hermes (OmniRoute) |
| Board / briefs / Cursor paste | Chief of Staff |

## UX source of truth

- `UX-SHELL.md`, `DESIGN.md`, `UX-BACKLOG.md`, fonts under NUC `silveran-ios\`
- Prune policy: `PODCASTS-SHELF-PRUNE.md`
- Icon: twin-pages final (bundle id unchanged)
- Stitch: https://stitch.withgoogle.com/projects/131401596261616247?pli=1

---

## Appendix — Personal Reader program plan (carried over from `main`/PR001)


## Product goal

Build a personal iPhone/iPad reading and listening app on top of Silveran Reader.

Silveran remains authoritative for Storyteller integration, ebook/audiobook position synchronization, audiobook playback, ebook rendering, read-aloud behavior, and book downloads.

Selected Enve Book Player concepts and components will be adapted for podcast subscriptions/playback, activity statistics, a reading journal, and a richer cover-first library.

The defining product principle is:

> A book is one story with multiple ways to consume it: Read, Listen, or Read Along.

Changing formats must never feel like switching between unrelated media items.

## Architectural guardrails

- `ProgressSyncActor` is protected infrastructure. Do not rewrite or bypass it for app features.
- Storyteller authentication, source-scoped `BookID`, locator serialization, and server/local timestamp reconciliation remain Silveran-owned.
- Podcasts use their own identity and progress stores and must never enter Storyteller progress synchronization.
- Statistics observe reading/listening activity. They never become canonical progress storage.
- Prefer new personal-reader feature boundaries over invasive edits to upstream Silveran files.
- Keep the fork easy to update from `kyonifer/silveran-reader`.

## PR001 — Foundation & upstream safety

- Document product architecture and protected Silveran boundaries.
- Document upstream synchronization workflow.
- Create initial personal-feature namespaces for Home, Library, Podcasts, Journal, Activity, and Podcast services.
- Add progress-model regression tests that establish core progress semantics before UI work begins.
- No intentional runtime UX changes.

## PR002 — Personal app shell

Introduce the iPhone/iPad shell with primary navigation:

**Home · Library · Podcasts · Journal**

Settings remains secondary. Add a persistent mini-player presentation that can later represent either book or podcast playback while leaving Silveran's reader/player engines intact.

## PR003 — Home & library redesign

Build a cover-first Home and Library experience using Silveran library and progress models.

Home includes current story, Continue, Recently Added, Finished, and Downloaded sections. Library includes adaptive grid/list presentation, search, filters, author/series browsing, sorting, and richer book detail.

When both ebook and audiobook formats exist, the UI represents them as one conceptual book with Read, Listen, and Read Along actions.

## PR004 — Activity tracking foundation

Add observational reading/listening session tracking with separate audiobook, ebook, and podcast activity categories.

Track daily totals, per-item totals, sessions, completions, and streaks without changing canonical Storyteller progress.

## PR005 — Journal & reading statistics

Create the Journal surface with weekly reading/listening totals, books finished, episodes finished, current/longest streaks, recent sessions, and per-book history. Add a year heatmap after validating daily-history cost and persistence.

## PR006 — Podcast data foundation

Adapt podcast infrastructure for RSS subscriptions and Apple podcast-directory discovery.

Introduce dedicated `PodcastShow`, `PodcastEpisode`, subscription, feed parsing, and persistence types. Podcast identity stays independent from Storyteller books.

## PR007 — Podcast library & discovery UI

Build the Podcasts tab with Up Next, Latest Episodes, Shows, Downloads, Discover, show pages, episode pages, subscription state, played state, and download state.

## PR008 — Podcast playback, queue & downloads

Add podcast playback, independent progress, queueing, auto-queue rules, variable speed, seek controls, sleep timer, Now Playing integration, AirPlay, resume, and offline downloads.

Only one audio domain may own playback at a time.

## PR009 — Unified Now Playing & CarPlay

Create one presentation layer over book and podcast playback. Extend CarPlay for books, podcasts, Up Next, and downloads while keeping podcast progress isolated from Storyteller sync.

## PR010 — iPad, widgets & polish

Finish the daily-driver experience with responsive iPad layouts, widgets, background refresh, storage management, podcast auto-download rules, accessibility, performance profiling, and a full Storyteller sync regression pass.

## Later candidates

- Apple Watch podcast controls/playback
- Siri/App Intents
- reading goals
- OPML podcast import/export
- smart collections
- podcast chapters and artwork
- transcript support
- search across podcast show notes
- reading-session notes
- ratings/reviews
- statistics export
