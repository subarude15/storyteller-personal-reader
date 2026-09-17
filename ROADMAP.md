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

- **Streaming Books — Phase 1: Explore ebooks** — one focused PR after tip `b8ca122`.
  Add a `Library | Explore` surface inside the existing Library tab (no sixth tab), backed only
  by an authorized/public-domain OPDS catalog (Standard Ebooks for v1). Browse/search/detail;
  **Read now** downloads a validated EPUB to temporary local cache and opens the existing
  Silveran reader; **Add to Library** sends that EPUB through the existing Storyteller import path.

**Next (strict order):**
1. **Streaming Books — Phase 2: public-domain audiobooks** — LibriVox browse/search and HTTPS
   streaming through the existing shared player / `AudioSessionActor`; no second player
2. **Finish tonight** — quick Home win
3. **Story Timeline** — distinctive but bigger
4. Soft: distinct **Couldn't save server** copy vs connection-failed

**Parked / out:** second concurrent player (shared NP stays); CarPlay; DSM/SMB; mainline Continue widget (Josh happy on Arena IPA; PR #23 closed not merged — reopen later with `ALTAppGroups` resolve if mainline should match); DRM catalogs; torrent/debrid sources; Bookracy/AudiobookBay and other scraper-backed acquisition.

**Do not start DSM/SMB, CarPlay, a second player, unlicensed/scraped catalogs, external recommendation APIs, or the Arena widget merge unless Josh reorders. Authorized public-domain catalog work is the narrow exception above; it must remain separate from local-library recommendations.**
## Shipped

### Product / sync
- [x] **More like this** book-detail rail — local Storyteller library only; series → author
  → tag-overlap ranking; PR #24 squash-merged at tip `b8ca122`; Simulator + Sideload green
  [Actions 35217017886](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35217017886)
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
- [~] **Continue home widget** — Josh live on **Arena IPA** (`ALTAppGroups` resolve; not “free AltStore can’t”). PR **#23** closed **not** merged so tip `b9b07ea` stays clean. Reopen clean PR later if mainline should match. Docs still say Parked until that lands.

### Stats
- [x] **SessionTracker local** — ebook / audiobook / readaloud / podcast → Home + Stats tab (`c627bbe`, Sideload [35006016694](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35006016694))
- [x] **Cross-device Stats sync** — tip `c5791ec` (`a5226d6` + BookServiceActor fix); private Storyteller collection `.inkamp.stats.v1` blob (same auth as place sync); session-id LWW merge (no double-count / no drop); footer Synced / Syncing… / Offline · local only; Settings last sync time; Sideload green [35028364424](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35028364424)
- [x] **Stats Retry sync** — tip `fdb5560`; Settings last-sync row + Stats footer tappable → Syncing… then Synced / Offline · local only; soft overall + per-step timeouts; Sideload green [35033759537](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35033759537)
- [x] **Stats push / description decode** — tip ``cf5c663``; Josh confirmed syncing; tolerate collection ``description`` objects (String or dict); isolate stats blob; ``pushed=false`` reason log; fail toast; Sideload green [35035504839](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35035504839)

---

## Next (strict order — do not reorder)

1. **Streaming Books Phase 2** — LibriVox/public-domain audiobook browse + HTTPS streaming through the shared player
2. **Finish tonight** — smallest Home win
3. **Story Timeline** — bigger distinctive cut
4. Soft: **Couldn't save server** copy anytime

### Soft UX polish (anytime)
- Soft polish pack → **Shipped** (`b9b07ea` / PR #22)
- Distinct **Couldn't save server** copy (≠ “Connection failed”) — still soft

## Later / ideas (not blocking)

**Streaming Books Phase 3** — configurable, user-controlled authorized OPDS providers after the
Standard Ebooks and LibriVox foundations are proven. **Discover books you don't have** remains a
later Goodreads-style, metadata-only discovery idea, intentionally separate from acquisition and
from the local-library **More like this** rail. Also later: Wrapped, series strip, Shortcuts.
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

**Later toys (only if reordered):** Story Timeline; Finish tonight; Wrapped/heat map; series strip; Shortcuts Continue; widgets; second player.
## Constraints

- Keep `SilveranKit`; do not merge Enve tree (modules + AGPL only)
- Storyteller = ebook / audiobook / readaloud; podcasts = RSS rail
- Streaming catalogs must be authorized/public-domain or explicitly user-controlled. No torrent,
  debrid, AudiobookBay, Bookracy, or HTML-scraper acquisition paths; never disable TLS validation.
- EPUB **Read now** means a complete, validated temporary download before opening — do not present
  it as progressive page streaming. Imported titles become normal Storyteller books.
- Explore-only items must not enter Library/Shelf or `LocalBookRecommendations`; they appear there
  only after explicit **Add to Library**. **More like this** remains Storyteller-library-only.
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
