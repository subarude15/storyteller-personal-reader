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

- [ ] **Podcast queue** — play-next / play-last + reorder. Tip ≥ ad-strip stub Sideload green. Local Cursor on NUC.

**Do not start real PrincessDonut / NAS strip ahead of queue UX.** Josh UI stamps (played+remaining text; slim mini-player) can land as polish alongside or right after queue.

---

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
- [x] **Ad-strip download / queue UX (v1 = UX + hooks + stub)** — tip `60a211b` (`c93deac` + shelf chip fix); Download sheet Original vs Clean (per-show last choice); Keep/queue → Clean pending; chips Original | Cleaning… | Clean; `PodcastAdStripPipeline` + `StubPodcastAdStripPipeline` (no-op copy Original → `audio.clean.*` sibling after ~1.2s; soft-fail → Original); player prefers Clean when chip == Clean; Original never deleted; Sideload green [35019916837](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35019916837)

### Shell polish
- [x] **Mini-player above tab bar** — per-tab inset (`be395da`, Sideload [35008731469](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35008731469)); Josh confirmed
- [x] **Mini / full player polish** — −15/+15, elapsed|scrub|remaining, podcast cover on mini (`b8c85f9` / tip ≥ `70866b7`, Sideload [35011914260](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35011914260)); Josh ready for next

### Stats
- [x] **SessionTracker local** — ebook / audiobook / readaloud / podcast → Home + Stats tab (`c627bbe`, Sideload [35006016694](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35006016694))

---

## Next (strict order — do not reorder)

### After queue UX
1. ~~Find shows~~ → **Shipped**
2. ~~Ad-strip download / queue UX (v1 stub)~~ → **Shipped**
3. ~~Podcast queue play-next / play-last + reorder~~ → **Now**
4. **Josh UI stamps (polish follow-up)**
   - Home Continue / Up next **and** Library cards: show **played time + remaining as text** (not only a bar) so finishability is obvious
   - Mini-player: **REMOVE scrubber and −15/+15** (accidental hits while swiping tabs/menus). Keep cover + title + play/pause (+ close)
   - Full Now Playing: **KEEP** scrub + −15/+15 + elapsed/remaining
5. **Cross-device Stats sync** — shared store; footer → “Synced across your devices”; merge by day (no double-count)

### UX polish (anytime after queue)
- Separate **Couldn’t save server** copy (≠ “Connection failed”)
- Empty state when URL prefilled but no saved Storyteller source
- Missing Storyteller covers (cosmetic; not a blocker)

---

## Later / ideas (not blocking)

- Silence-trim spike
- **Real PrincessDonut ad-strip worker** (NAS; OmniRoute free-first via `/v1` for any LLM step) — replace `StubPodcastAdStripPipeline`; app UX+hooks already shipped
- Cross-device Stats sync (shared store; footer Synced; merge by day)
- **In-app YouTube** (not RSS Audio|Video enclosures) — separate from dual-enclosure A|V sheet
- Glance / Watch tile: now-playing + Continue deep-link
- One-tap LAN failover: public URL → `http://192.168.1.2:1800` on home Wi‑Fi
- CarPlay (out of current build scope)


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
