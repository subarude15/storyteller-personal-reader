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

**Product gate (proven 2026-09-15):** Storyteller progress sync phone ↔ iPad — same spot after listen/read. That is the core reason for ink+amp.

---

## Now (do first)

_(none queued — pick the next Later item. Explicit reject below still applies.)_

**Explicit reject:** Playtorio, TorBox, magnets, LibGen, Audible scrape, DRM strip, and free-catalog Explore browse (Standard Ebooks / public OPDS shelves / Download / Import). Do not start second player, CarPlay, or DSM/SMB unless Josh reorders.

## Shipped

- [x] **Book-first audiobook resolution** — workflow is select/request book → Find audiobook options → match provider results to that work → choose an audiobook. LibriVox/public-domain only, queried after the tap, not when opening a book, scrolling search, or refreshing the library. Matched versions stay formats of the selected work (no extra library rows, no second player). Resume is device-local. Does **not** complete streaming, torrent, or debrid phases.
- [x] **Resolved audiobook offline downloads** — merged in #46 (`a35f347`). From the same audiobook options sheet: Download, progress, Cancel, Retry, Play Offline, Remove Download. Files live under app storage keyed by work + provider + provider item, with a local manifest. Complete copies play through the existing audiobook player and keep the same resume identity. Does **not** complete torrent or debrid phases.
- [x] **LazyLibrarian request integration** — merged in #47. Select book → Request Ebook / Audiobook / Both → LazyLibrarian. The app matches the selected work, adds that one LazyLibrarian book if needed, then `queueBook` + `searchBook` for the missing format. Request accepted is not downloaded. Shelfarr stays. Storyteller still imports through the normal library sync. Does **not** complete torrent or debrid phases.
- [x] **Mobile Storyteller upload hardening** — merged in #44 (`bac55cd`) plus follow-up #48. Same Import / Add Book sheet: file-backed Tus upload (no full audiobook in memory), Storyteller destinations only when `bookCreate` is confirmed, one book UUID across retry, honest processing / partial / cancel states, wider Files picker types, poll-only Check again, longer visibility waits, folder UUID reuse on retry. Original Files documents are not modified.

### Product / sync
- [x] **Ideas v2 (polish)** — Library | Ideas recommends titles not already in the Storyteller library (title/author/ISBN), deduped by title+author or ISBN. Every row shows a why-line (never blank); empty-reason paths are dropped. Detail shows cover, title, author, a labeled **Why** chip, and a real description — `first_sentence` from search.json, backfilled from `/works/{key}.json` description, with subjects + year when present and a graceful "No description on Open Library" fallback. Denser: author 12 / series-tag 10 hits, ~24–36 kept; last-good cache when offline. Save idea only — no download. **More like this** stays library-only.
- [x] **Ideas v3** — **Not interested** (swipe + button) dismisses by stable id (work key / ISBN / title+author) and refills; explicit **Because you like…** anchors on every row/detail; real synopsis (work → edition → `first_sentence`); denser (author 15 / series-tag 15 hits, 8+8 queries, ~24–36 kept). No download — Save idea only. **More like this** stays library-only.
- [x] **Ideas English-first summaries** — Open Library description/edition text prefers `eng`/`en` (language-tagged values + `languages` array); search biased `language:eng`; English editions preferred for work→edition synopsis; non-English blurbs never surface as the main summary (English subjects / "No English description on Open Library" fallback). Ideas aren't dropped for lacking an English blurb.
- [x] **Ideas Interested / Not interested wired + Saved visible** — Ideas now has an **Ideas | Saved** segmented control. **Not interested** (row swipe + detail button) persists by stable id, removes the row immediately, refills when the pool thins, and stays gone across relaunch. **Save idea** (row swipe + detail button) persists and the title moves into a visible **Saved** list (bookmark state, Remove, Clear all). No download/import.
- [x] **Home long-press medium picker** — Home Continue / Up next / Finish tonight: tap = last-used medium; long-press = action sheet of only the media the item actually has (Readaloud / Audiobook / Ebook, or podcast Audio / Video), opening the existing player/reader host — no new player stack.
- [x] **Finish tonight + Couldn’t save server** — Settings Bedtime (default 10:30 PM, local only); Home card up to 3 in-progress picks that fit the remaining window (hide when empty or past bedtime); Storyteller save failures show **Couldn’t save server** (Test Connection keeps distinct copy).
- [x] **Delete from Library (iOS)** — Options → Delete from Library → Storyteller `deleteBook`. Confirm, then the book leaves Library, Home Continue, and the Continue widget. Folder delete is unchanged.
- [x] **Purge unpaid ingest + Ideas for later v1** — removed Playtorio, TorBox, magnets, LibGen, Audible scrape, RaveBookSearch, and free-catalog Explore (Standard Ebooks / public OPDS browse / Download / Import). Library segment is **Library | Ideas**: habit-ranked metadata suggestions (series gaps, same authors, overlapping tags; recency-weighted) with optional Open Library lookup and local Save idea. No download. **More like this** stays on owned book detail. Storyteller sync, LAN failover, podcasts, player, and local Import stay.
- [x] **Streaming Books Phase 1: Explore ebooks + lawful source foundation** — tip `0d71be3`;
  `Library | Explore` segment; Standard Ebooks (public Atom new-releases) + user OPDS + direct
  HTTPS EPUB; Read now via existing Silveran reader; Add to Library via Storyteller upload;
  Simulator + Sideload green
  [Actions 35229145644](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35229145644)
- [x] **More like this** book-detail rail — local Storyteller library only; series → author
  → tag-overlap ranking; PR #24 squash-merged at tip `b8ca122`; Simulator + Sideload green
  [Actions 35217017886](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35217017886)
- [x] Storyteller Cloudflare Access Google bypass (server)
- [x] Storyteller URL **prefill** (not auto-save)
- [x] Keychain Save on AltStore (drop Data Protection / no `KEYCHAIN_ACCESS_GROUP` on Sideload) — verified
- [x] Library/Shelf: undownloaded tap → book detail (`84a07a7`); downloaded open path
- [x] Dead-tap fix for downloaded titles (`fde181c`)
- [x] **Phone ↔ iPad progress sync proven** (Continue + Synced chip)
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
- [x] **Podcast release dates + new activity** — episode rows show a short publish date (`Yesterday`, `3 days ago`, `Sep 18, 2026`). Subscribed overview shows a small **New** star chip when a later episode arrives after that show was last opened. Opening the show clears it; refreshing the overview does not. Watermark is device-local (`PodcastActivityStore`), not the subscription sync blob, so acknowledging a show cannot outrank an unsubscribe. Tip `27a91b2`; Sideload green [35416316929](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35416316929)

### Shell polish
- [x] **Mini-player above tab bar** — per-tab inset (`be395da`, Sideload [35008731469](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35008731469)); Josh confirmed
- [x] **Mini / full player polish** — −15/+15, elapsed|scrub|remaining, podcast cover on mini (`b8c85f9` / tip ≥ `70866b7`, Sideload [35011914260](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35011914260)); Josh ready for next
- [x] **Mini-player slim** — scrub + −15/+15 removed from mini (status-cluster cut)

### Widgets
- [x] **Continue home widget** — tip `cc910d9` (PR #26; Arena `ALTAppGroups` resolve); Josh confirmed green. Wipe old blank tiles on install.
- [x] **Continue + Up next (3)** — medium tile shows HomeMixedQueue Now (cover, title, progress, existing play/pause) + up to 3 Up next. Kind is now `inkamp.continue.upnext.v1` (gallery **Continue + Up next**); the old `InkAmpContinueWidget` kind is retired so iOS cannot keep the Continue-only tile. App Group (`ALTAppGroups` → configured → fallback). Up next taps `punkrally://continue?item=`. Empty: "Nothing in progress". Free AltStore WidgetKit can stay flaky. See `docs/CONTINUE_WIDGET.md`.

### Stats
- [x] **SessionTracker local** — ebook / audiobook / readaloud / podcast → Home + Stats tab (`c627bbe`, Sideload [35006016694](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35006016694))
- [x] **Cross-device Stats sync** — tip `c5791ec` (`a5226d6` + BookServiceActor fix); private Storyteller collection `.inkamp.stats.v1` blob (same auth as progress sync); session-id LWW merge (no double-count / no drop); footer Synced / Syncing… / Offline · local only; Settings last sync time; Sideload green [35028364424](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35028364424)
- [x] **Stats Retry sync** — tip `fdb5560`; Settings last-sync row + Stats footer tappable → Syncing… then Synced / Offline · local only; soft overall + per-step timeouts; Sideload green [35033759537](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35033759537)
- [x] **Stats push / description decode** — tip ``cf5c663``; Josh confirmed syncing; tolerate collection ``description`` objects (String or dict); isolate stats blob; ``pushed=false`` reason log; fail toast; Sideload green [35035504839](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35035504839)
- [x] **Story Timeline** — Stats now has a **Stats | Timeline** segmented control. Timeline shows day-grouped reading/listening history (owned books + podcasts, newest first): cover thumb, title, medium chip (Ebook / Audiobook / Readaloud / Podcast), and a time · duration · % line. Tapping Continues that item in its recorded medium via the existing player/reader host (same path as Home long-press). Sessions record their actual medium (`ebook`/`audiobook`/`readaloud`/`podcast`); legacy sessions fall back to kind + `podcast/` prefix. Offline = last-known local ledger; empty state = "Sessions show up here as you read and listen."
- [x] **Story Timeline polish: no ghost rows** — orphan/unresolved beats render at full opacity with an **Unavailable** chip (same capsule family as the medium chips) instead of the faded 0.55-opacity ghost; tap stays a no-op, resolvable beats unchanged.

---

## Next (strict order — do not reorder)

Story Timeline is shipped. Ideas/Browse search landed on `6e5ecae` and stays as-is. This cut is Continue + Up next.

### After Story Timeline
1. ~~**Finish tonight**~~ → **Shipped**
2. ~~**Story Timeline**~~ → **Shipped**
3. ~~Soft: **Couldn't save server**~~ → **Shipped** (same PR as Finish tonight)
4. ~~**Ideas/Browse OL search**~~ → **Shipped** (`6e5ecae`; unowned cards, Save / Not interested; Saved stays local-filter only)
5. ~~**Continue + Up next widget**~~ → **Shipped** (`482fe8b`; medium Now + 3 Up next from `HomeMixedQueue`; Sideload [35390329291](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35390329291))
6. ~~Continue widget restore~~ → **smoke** tip `cc910d9` (PR #26)
7. ~~**Podcast release dates + new-activity chip**~~ → **Shipped** (next podcast UI cut; does not reorder items above; Sideload [35416316929](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35416316929))

### Soft UX polish (anytime)
- Soft polish pack → **Shipped** (`b9b07ea` / PR #22)
- ~~Distinct **Couldn't save server** copy (≠ “Connection failed”)~~ → **Shipped**

## Later / ideas (not blocking)

**Ideas v2 is shipped** (unowned titles, why-lines, local Save idea; no download). Wrapped, series strip, and Shortcuts stay later.
**Soft Later:** Home tap / long-press medium picker.
**Second player** remains parked (shared NP stays).

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

**Later toys (only if reordered):** Wrapped/heat map; series strip; Shortcuts Continue; widgets; second player.
## Constraints

- Keep `SilveranKit`; do not merge Enve tree (modules + AGPL only)
- Storyteller = ebook / audiobook / readaloud; podcasts = RSS rail
- **Explicit reject:** Playtorio, TorBox, magnets, LibGen, Audible scrape, DRM strip, and free-catalog Explore browse (Standard Ebooks, public OPDS shelves, Download / Import from remote catalogs). Ideas are metadata and a local save list only — no download, no full-book fetch, no unpaid source links.
- EPUB files the user already has still open in the existing reader. Imported titles become normal Storyteller books via the existing local / phone import.
- **Ideas for later** must not enter Library, Shelf, or sync. **More like this** remains Storyteller-library-only (series → author → tags) on owned book detail.
- Reuse the existing ebook reader and shared audio session/player. Preserve Storyteller Read ↔ Listen
  position sync for imported/owned books; do not add a second player.
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
