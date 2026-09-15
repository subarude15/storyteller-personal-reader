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

- Quiet — no active P0. Josh confirmed ship: mini-player above tabs + podcast resume (`be395da`).
- **When Josh asks:** mini-player −15 / +15 skip + podcast cover on mini-player (polish; not blocking).
- **Later (do not start yet):** Podcast Index / Find shows; optional cross-device Stats sync.

**Board is clear until Josh picks polish or Later.**

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

### Shell polish
- [x] **Mini-player above tab bar** — per-tab inset (`be395da`, Sideload [35008731469](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35008731469)); Josh confirmed

### Stats
- [x] **SessionTracker local** — ebook / audiobook / readaloud / podcast → Home + Stats tab (`c627bbe`, Sideload [35006016694](https://github.com/subarude15/storyteller-personal-reader/actions/runs/35006016694))

---

## Next (strict order — do not reorder)

### 1. Stats follow-ups
1. ~~Hook local SessionTracker~~ → **Shipped**
2. Optional: cross-device Stats sync (shared store; footer → “Synced across your devices”; merge by day — no double-count)
3. Then Later: Podcast Index / Find shows

### UX polish (anytime after Now, not ahead of Stats)
- Separate **Couldn’t save server** copy (≠ “Connection failed”)
- Empty state when URL prefilled but no saved Storyteller source
- Missing Storyteller covers (cosmetic; not a blocker)

---

## Later / ideas (not blocking)

- **Next polish (when Josh asks):** Mini-player −15 / +15 skip + podcast cover art on mini-player
- Optional cross-device Stats sync (shared store; footer → Synced; merge by day)
- Silence-trim spike
- AI sponsored/ad strip (async post-download; on-device / NAS / OmniRoute)
- Glance / Watch tile: now-playing + Continue deep-link
- One-tap LAN failover: public URL → `http://192.168.1.2:1800` on home Wi‑Fi
- CarPlay (out of current build scope)
- Podcast search — Podcasts tab Find shows → iTunes/Podcast Index lookup → art + Subscribe (resolves RSS); paste-URL stays as fallback. After Home mixed + Stats.

---

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
