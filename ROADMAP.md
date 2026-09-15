# ink+amp — roadmap

Living board for Cursor, Hermes, and the Grok crew. **Update this file when tips/IPAs land** so agents follow current Now items — not stale Keychain / “wire shared player” work.

| | |
|---|---|
| **Repo** | https://github.com/subarude15/storyteller-personal-reader |
| **Branch** | `punk-rally-ios` |
| **Bundle ID** | `com.punkrally.reader` (do not change) |
| **NUC workspace** | `C:\Users\imalo\dev\silveran-ios\silveran-reader` |
| **Docs beside repo** | `C:\Users\imalo\dev\silveran-ios\` (mirrors; in-tree copies at repo root) |
| **Policy in repo** | `PODCASTS-SHELF-PRUNE.md` |

**Product gate (proven 2026-09-15):** Storyteller place sync phone ↔ iPad — same spot after listen/read. That is the core reason for ink+amp.

---

## Now (do first)

- [x] **Josh:** Sideload tip **`3639b67`** shared Now Playing + one speed chip — smoke-tested / **shipped**
- [x] **Shelf auto-prune (podcast downloads only)** — implemented this cut (await Sideload IPA)

**Next up after Sideload green:** Audio | Video episode sheet. Do not retouch player/speed.

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
- [x] ink+amp display name + twin-pages AppIcon (keep `com.punkrally.reader`)
- [x] Settings half of PR 6
- [x] CI: Builtin/StoryAlign / Xcode pin / Sideload unsigned IPA pipeline

### Podcasts
- [x] Shared Now Playing + playback speed (`66fadcd` + compile fix `3639b67`) — Josh smoke-tested / **shipped** (one speed chip only)
- [x] Shelf auto-prune for podcast downloads (Settings → Podcasts → Downloads; podcasts-only ledger)

---

## Next (strict order — do not reorder)

### 1. Shelf auto-prune (podcast downloads only) — **SHIPPED (this PR)**
**Owner:** Smokey / Hermes / Cursor · **Policy:** `PODCASTS-SHELF-PRUNE.md`

- [x] Settings → Podcasts → Downloads: Auto-clean (default On), Remove when finished (On), Max age (30d), Max downloads (50), Protect if played ≥10%, Pin/Keep, Clean now + preview
- [x] First time Auto-clean turns On → one-time explainer sheet (then silent overnight prune)
- [x] Podcasts-only — never touch ebook / audiobook / readaloud Shelf or Storyteller local media
- [x] Optional Shelf footer: `Pruned N episodes · Settings`
- [x] Acceptance covered by `PodcastShelfPrunePolicyTests`
- Do **not** retouch Keychain, player/speed wiring, or add a second speed dial

### 2. Audio | Video episode sheet
- When an episode has dual enclosures, picker remembers preference **per show**
- After prune; before Home mixed queue / Stats sync

### 3. Home mixed Continue / Up next
- One mixed queue: books **and** podcasts, last-touched first
- Podcast cards: **POD** badge + show art; books keep cover + READ/LISTEN/SYNC
- Do **not** split into two Home rails
- Also: real covers on Continue / Up next (not empty book icons)

### 4. Stats
1. Hook local `SessionTracker` to reader/player events (zeros today are expected — M1 never wired this)
2. Optional later: cross-device Stats sync (single phone+iPad number via shared store; footer flips from “stay on this iPhone” to “Synced across your devices”; merge by day — no double-count)

### UX polish (anytime after Now, not ahead of 1–2)
- Separate **Couldn’t save server** copy (≠ “Connection failed”)
- Empty state when URL prefilled but no saved Storyteller source
- Missing Storyteller covers (cosmetic; not a blocker)

---

## Later / ideas (not blocking)

- Silence-trim spike
- AI sponsored/ad strip (async post-download; on-device / NAS / OmniRoute)
- Glance / Watch tile: now-playing + Continue deep-link
- One-tap LAN failover: public URL → `http://192.168.1.2:1800` on home Wi‑Fi
- CarPlay (out of current build scope)

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
