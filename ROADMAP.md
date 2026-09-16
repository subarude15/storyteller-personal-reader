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

- **Glance / Lock Screen** — lean on **system Now Playing** first; Home Screen widgets stay parked on free AltStore. Soft polish anytime.

**Josh picks reorder anytime:** LAN failover · YouTube playhead persist · SponsorBlock · StoryAlign phone import.

**Do not start CarPlay / Watch companion / paid App Groups / Home Screen widgets unless Josh reorders.**
## Shipped

### Product / sync
- [x] Storyteller Cloudflare Access Google bypass (server)
- [x] Storyteller URL **prefill** (not auto-save)
- [x] Keychain Save on AltStore (drop Data Protection / no `KEYCHAIN_ACCESS_GROUP` on Sideload) — verified
- [x] Library/Shelf: undownloaded tap → book detail (`84a07a7`); downloaded open path
- [x] Dead-tap fix for downloaded titles (`fde181c`)
- [x] **Phone ↔ iPad place sync proven** (Continue + Synced chip)

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
- [x] **Episode status cluster + show filters + Josh UI stamps** — tip `b719921`; download glyph · Clean chip (incl. Clean failed) · Xm left/Played; show filters All|Downloaded|In progress|Clean pending; Shelf POD chrome; mini-player cover+title+play/pause(+close) only (scrub/−15/+15 stay on full Now Playing); Home/Library finishability text via `PlaybackFinishabilityCopy`; Sideload green [35023934089](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35023934089)
- [x] **Podcast play queue** — tip `2f7deb4`; Play Next / Play Last in episode menus; `PodcastPlaybackQueueStore` + editable `PodcastPlaybackQueueView` (drag reorder, remove, clear finished); auto-advance on finish via shared player; persisted upcoming order; Sideload green [35025614228](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35025614228)
- [x] **P0 Podcast resume / Home Continue stall** — tip `7eb0a9e`; Josh confirmed; Loading until playhead advances; Pause only when truly playing; Sideload green [35031138576](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35031138576)

### Shell polish
- [x] **Mini-player above tab bar** — per-tab inset (`be395da`, Sideload [35008731469](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35008731469)); Josh confirmed
- [x] **Mini / full player polish** — −15/+15, elapsed|scrub|remaining, podcast cover on mini (`b8c85f9` / tip ≥ `70866b7`, Sideload [35011914260](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35011914260)); Josh ready for next
- [x] **Mini-player slim** — scrub + −15/+15 removed from mini (status-cluster cut)

### Widgets
- [~] **Continue home widget** — **Parked on free AltStore** (Josh+crew). Code in-tree through `inkamp.continue.v4` (`3cf76da`); Sideload does **not** embed the appex. Revisit when paid Apple ID or SideStore grants App Groups + reliable WidgetKit. Deep link `punkrally://continue` stays for in-app / Shortcuts.
### Stats
- [x] **SessionTracker local** — ebook / audiobook / readaloud / podcast → Home + Stats tab (`c627bbe`, Sideload [35006016694](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35006016694))
- [x] **Cross-device Stats sync** — tip `c5791ec` (`a5226d6` + BookServiceActor fix); private Storyteller collection `.inkamp.stats.v1` blob (same auth as place sync); session-id LWW merge (no double-count / no drop); footer Synced / Syncing… / Offline · local only; Settings last sync time; Sideload green [35028364424](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35028364424)
- [x] **Stats Retry sync** — tip `fdb5560`; Settings last-sync row + Stats footer tappable → Syncing… then Synced / Offline · local only; soft overall + per-step timeouts; Sideload green [35033759537](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35033759537)
- [x] **Stats push / description decode** — tip ``cf5c663``; Josh confirmed syncing; tolerate collection ``description`` objects (String or dict); isolate stats blob; ``pushed=false`` reason log; fail toast; Sideload green [35035504839](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35035504839)

---

## Next (strict order — do not reorder)

### After Stats sync
1. ~~Podcast queue~~ → **Shipped** (`2f7deb4`)
2. ~~Cross-device Stats sync~~ → **Shipped** (`c5791ec`)
3. ~~NAS `AD_STRIP_URL` worker~~ → **Shipped** (`e00d800` + `:20129`; Josh confirmed Clean ad-free)
4. ~~Hybrid video~~ → **Shipped** (`87b56cd`; Josh confirmed)
5. ~~Continue widget scaffold~~ → landed; **Parked on free AltStore** (no Sideload appex); revisit paid/SideStore
6. ~~Silence-trim~~ → **Shipped** (`d8af263`; Josh verified)
7. ~~In-app YouTube / Match~~ → **Shipped** (`a0722eb`; Josh confirmed)

### Soft UX polish (anytime)
- ~~Stats Retry sync~~ → **Shipped** (`fdb5560`)
- ~~Stats push / description decode~~ → **Shipped** (`cf5c663`) — Josh confirmed
- Cleaning… chip must not look like episode remaining (job ETA or plain Cleaning…; keep Xm left on progress separately) — status cluster already separates job chip from Xm left
- Separate **Couldn't save server** copy (≠ “Connection failed”)
- Empty state when URL prefilled but no saved Storyteller source
- Missing Storyteller covers (cosmetic; not a blocker)

---
## Later / ideas (not blocking)

Strict order (Smokey / Nas-ty):
1. ~~NAS `AD_STRIP_URL` worker~~ → **Shipped** (`e00d800` + `:20129`)
2. ~~Silence-trim~~ → **Shipped** (`d8af263`; Josh verified)
3. ~~Full in-app YouTube embed/SDK~~ → **superseded** by hybrid + in-app YouTube v1 + Match
4. ~~Match on YouTube~~ → **Shipped** (`a0722eb`; Josh confirmed)
5. **YouTube playhead persist** — save resume per matched video id (local first, like podcast playheads; Storyteller sync only after local is solid). Separate from Clean/ad-strip.
6. **SponsorBlock-style skip** — Later only; additive seek on in-app YouTube (not podcast Clean)
7. **Glance / Watch tile** → **Now** (system Now Playing first; widgets parked until paid/SideStore)
8. **One-tap LAN failover**: public URL → `http://192.168.1.2:1800` on home Wi‑Fi
9. **Phone import → StoryAlign read-aloud** — Library **Import** (EPUB and/or MP3) → upload to Storyteller on NAS → server align → ink+amp refreshes library / Continue
10. **CarPlay** / **Apple Watch** (out of current AltStore Sideload scope)

**P1000 (Later, not ahead of Glance / LAN / StoryAlign / YouTube playhead):** **Podcast cross-device sync** — subscriptions + playheads only. **Downloads stay per-device**.
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
