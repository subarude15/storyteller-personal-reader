# punk+rally Reader — UX Shell (iOS, phone-first)

**For:** Joshua / Hermes (Swift on OmniRoute) + Nas-ty Girl (Storyteller)  
**Prepared by:** Ui And Design · 2026-09-14  
**Bases:** Silveran Reader (sync / readaloud / Storyteller) + Enve Book Player (library chrome, podcasts, stats)  
**Server:** `https://storyteller.banditoburrito.xyz` · OPDS title `punk+rally books`

Deliverable format:
1. Design Concept & Architecture  
2. Google Stitch prompt  
3. Design tokens / DESIGN.md  
4. Component notes for Hermes (not full Swift)

---

## 1. Design Concept & Architecture

### Intent
A **private, phone-first reading app** that feels like Silveran’s sync brain (ebook / audiobook / readaloud, one place across modes and devices) with Enve’s **prettier library, podcast rail, and reading stats**. Visual voice: uncluttered, punk+rally-adjacent (high contrast, confident type, no clutter) — **full light + dark app chrome that follows iOS system appearance** (not dark-only). Reading comfort first; burnt orange + gold accents in both schemes.

### Information architecture (5 tabs + overlays)

| Tab | Job | Primary source |
|-----|-----|----------------|
| **Home** | Continue listening/reading, sync status, quick stats strip | Storyteller progress + local |
| **Library** | Browse full catalogue, filter by kind / series | Storyteller `GET /api/v2/books` (or `/api/books`) |
| **Shelf** | Downloaded / offline bookshelf | Local + Silveran download model |
| **Podcasts** | Shows + episodes | **Enve-only** (not Storyteller) |
| **Stats** | Reading/listening time, streaks, finished | Local aggregates (Enve-inspired); Storyteller may not expose rich stats |

**Overlays / stacks (not tabs):**
- Auth stack: No server → Login → (optional) device pairing  
- Book detail sheet  
- Reader (ebook / readaloud highlight) — SilveranKit  
- Now Playing (audio / readaloud) — full screen from mini-bar  
- Settings (server, appearance, playback defaults, sleep timer)

### Content model (visible kinds)

| Kind | Badge | Behavior |
|------|-------|----------|
| Ebook | `READ` | Opens reader |
| Audiobook | `LISTEN` | Opens player |
| Readaloud | `SYNC` | Reader + audio; mid-sentence mode flip keeps place |
| Podcast | `POD` | Separate rail; never mixed into Storyteller catalogue filters |

### Key screens

**A. Connect server (unauthenticated cold start)**  
- Wordmark / mark: punk+rally books  
- Field: Storyteller base URL (placeholder `https://storyteller.banditoburrito.xyz`)  
- Helper: “Use the web UI root — not an invite link”  
- Primary: Continue  
- Secondary: “I have an invite” (opens `/invite/…` in Safari/ASWebAuth if needed)

**B. Sign in**  
- Email/username + password → `POST /api/v2/token` (fallback `/api/token`)  
- Alt: “Sign in with browser” → OPDS oauth (`/opds/auth/auth.json` → `/opds/authorize`)  
- Error: map 401 to plain “Wrong email or password”  
- Success → Home

**C. Home**  
1. Greeting + sync chip (`Synced` / `Syncing…` / `Offline · N on shelf`)  
2. **Continue** hero card (cover, title, kind badge, progress ring, mode toggle if readaloud)  
3. Horizontal **Up next** (3–5)  
4. Compact stats strip: Today · This week · Streak (taps → Stats tab)  
5. Mini-bar if audio/readaloud active (pinned above tab bar)

**D. Library (Browse)**  
- Search field  
- Segmented / chip row: All · Ebook · Audio · Readaloud · Series  
- Cover grid 2-col phone (3-col large phone), 8pt gutters  
- Series: derived locally from catalogue (Issa/Silveran pattern) — series row expands to horizontal covers  
- Empty: skeleton while fetching; never flash “no books” during load  
- Pull to refresh; offline banner if catalogue stale

**E. Shelf (Bookshelf / downloads)**  
- Same card chrome as Library  
- Filters: All downloaded · Ebook · Audio · Readaloud  
- Per-item: download state, size, remove  
- Empty state: “Nothing offline yet — grab titles from Library”

**F. Podcasts (Enve rail)**  
- Shows grid / list  
- Show detail → episodes  
- Subscribe / add feed  
- Player uses same mini-bar + Now Playing chrome as audiobooks (shared player shell, different source)

**G. Stats**  
- Hero: time this week (listen + read split)  
- Cards: streak, books finished (30d / year), avg session  
- Simple bar chart last 7 days  
- Footer note: “Stats stay on device” (privacy, matches Silveran ethos)

**H. Book detail**  
- Large cover, title, authors, series, kind badge  
- Progress + last device sync time  
- Primary CTA: Continue / Download / Read / Listen  
- Readaloud: segmented **Read | Listen** (same progress)  
- Secondary: sleep timer shortcut, speed (audio)

**I. Mini-bar + Now Playing**  
- Mini: cover thumb, title, play/pause, scrub or chapter chevron; **sync badge** (cloud check when place pushed)  
- Full Now Playing: art, scrubber, speed, sleep, chapter list, AirPlay  
- Readaloud: “Following text” toggle + jump-to-highlight

**J. Reader (ebook / readaloud)**  
- Defer deep chrome to Silveran (fonts, margins, search)  
- Shell requirement: floating mode chip for readaloud; highlight layer first-class; don’t invent a second reader

### Interaction notes
- **One progress** across ebook↔audio for readaloud; flipping modes never resets place.  
- **Browse vs Shelf** is explicit (Silveran must-keep) — don’t merge into one ambiguous library.  
- Sync chip is always glanceable on Home + mini-bar.  
- Skeletons on Library/Shelf; no false empty.  
- Touch targets ≥44pt; tab bar 5 items max (already).  
- **App chrome:** follow system (Light / Dark). Optional Settings: System / Light / Dark.
- **Reader page only:** Night / Sepia / Paper via Aa — never recolors tabs, library, or mini-bar.

### Layout strategy
- Safe-area aware; bottom tab + optional mini-bar (mini-bar sits **above** tab bar, 56pt).  
- 8pt / 4pt spacing grid throughout.  
- Covers: consistent 2:3 aspect, rounded 8pt, subtle elevation — no mixed icon/photo weight (same lesson as Smokey bottle cards).  
- Typography: display for titles (tight), UI sans for chrome; **ebook body** offers Silveran fonts **plus Born2Root Fast Font** pack (`Fast_Serif`, `Fast_Sans`, `Fast_Sans_Dotted`, `Fast_OpenDyslexic`, `Fast_Mono`) — default body **Fast Serif**.

---

## 2. Google Stitch prompt

Paste into Stitch as one screen set (iPhone 15 / 390×844). Generate: Home, Library, Shelf, Podcasts, Stats, Sign-in, Book detail, Mini-bar+Library combo.

```
Design a native iOS reading app UI (iPhone 15, 390×844) named "punk+rally" for a private Storyteller library. Uncluttered, high-contrast, modern — not neon chaos. Aesthetic: quiet punk / rally. **Generate BOTH light and dark chrome** (follow iOS system). Dark: charcoal #0B0B0C bg, warm off-white text. Light: warm paper #F7F5F2 bg, near-black #1A1814 text. Shared accent burnt orange (#E85D04) and gold (#E1B46E) in both. 8pt spacing grid, generous whitespace, accessible contrast. SF Pro for UI; optional condensed display for the wordmark only.

App structure: bottom tab bar with five tabs — Home, Library, Shelf, Podcasts, Stats. Optional mini player bar (56pt) sits above the tab bar when audio is playing.

SCREEN 1 — Sign in
Top: circular mark + wordmark "punk+rally books". Subtitle "Storyteller · private cellar". Centered card: email field, password field, primary filled button "Sign in" in burnt orange, secondary text button "Sign in with browser". Footer muted text "Server: storyteller.banditoburrito.xyz". Empty state only — no clutter.

SCREEN 2 — Home
Top status row: "Good morning" + small sync chip "Synced" with cloud-check icon. Large "Continue" card: 2:3 book cover left, title, author, kind badge "SYNC" (readaloud), thin progress ring 62%, secondary line "Ch 12 · synced 2m ago", primary button "Continue". Below: horizontal "Up next" row of 3 smaller covers with titles. Below: compact stats strip three equal cells — "42m today", "5h this week", "4 day streak". If playing: mini-bar above tabs with cover thumb, title, play/pause, tiny sync badge.

SCREEN 3 — Library
Title "Library". Search field "Search punk+rally books". Horizontal chips: All (selected), Ebook, Audio, Readaloud, Series. 2-column cover grid, each cell: 2:3 cover image, title (2 lines max), author (1 line muted), small kind badge corner (READ / LISTEN / SYNC). Skeletons not empty. Pull-to-refresh implied.

SCREEN 4 — Shelf
Title "Shelf". Subtitle "Downloaded · offline ready". Same cover grid chrome as Library but with a small download-complete check on each cover. Empty-state variant also: illustration-free, muted text "Nothing offline yet" + button "Browse Library".

SCREEN 5 — Podcasts
Title "Podcasts". Segment Shows | Latest. Show list with round/square art, show title, author, episode count. Distinct "POD" badge so it never looks like Storyteller books. Top trailing "+" Add feed.

SCREEN 6 — Stats
Title "Stats". Hero big number "5h 12m" with label "This week" and a dual mini legend Read vs Listen. 7-day bar chart. Three cards in a row: Streak 4, Finished 2, Avg session 28m. Footer caption "Stats stay on this iPhone".

SCREEN 7 — Book detail
Large cover top, kind badge SYNC, title, author, series name as tappable chip. Progress bar + "62% · last on iPhone". Segmented control Read | Listen. Primary orange button "Continue". Secondary "Download". Row of icons: speed, sleep timer, bookmark.

SCREEN 8 — Now Playing (audiobook)
Full-bleed blurred cover background, sharp cover center, title, author. Scrubber with chapter marks. Controls: back 15s, play/pause, forward 30s. Speed 1.25x chip, sleep 15m chip. Sync badge "Place saved". Close chevron down.



SCREEN 9 — Reader (ebook, Fast Font)
Reader page (Night theme example): background #0B0B0C, text #F4F1EA in **Fast Serif** — chrome around reader still follows system (bionic/speed-reading face: slightly heavier/artificial fixation on initial letters of words — describe as "bold-leading letterforms for faster reading", do not invent a fake font name other than Fast Serif). Chapter title small gold. Body ~18pt, comfortable line height 1.5, margins 20pt. Floating bottom chrome: Aa (font), progress scrub, mode chip "Read" with Listen available. Kind badge SYNC if readaloud. Mini sync chip top trailing.

SCREEN 10 — Reader Aa sheet
Bottom sheet "Typography". Font list with checkmarks: Fast Serif (selected), Fast Sans, Fast Sans Dotted, Fast OpenDyslexic, then a divider "More fonts", then system-style placeholders (Georgia, Palatino). Size stepper, line spacing, theme Night | Sepia | Paper. Caption: "Fast Font by Born2Root — open source".

Also note in every reader-related screen: UI chrome stays SF Pro; only book body uses Fast Font family.

Visual rules: no cluttered collages; no Comic Sans; no light gray-on-gray; covers consistent crop; tab bar icons simple line style; burnt orange for primary CTAs only; gold for badges and sync accents; background #0B0B0C, surface #161618, border #2A2A2E.
```

---

## 3. Design tokens / DESIGN.md

```markdown
# DESIGN.md — punk+rally Reader (iOS)

## Brand
- Name: punk+rally (library OPDS: "punk+rally books")
- Voice: short, cellar-quiet, no corporate fluff
- Platform: iOS first (Cursor iOS / phone); SwiftUI

## Color (dark app chrome — default)

| Token | Hex | Use |
|-------|-----|-----|
| `--bg` | `#0B0B0C` | App background |
| `--surface` | `#161618` | Cards, sheets |
| `--surface-2` | `#1E1E22` | Elevated / pressed |
| `--border` | `#2A2A2E` | Hairlines |
| `--text` | `#F4F1EA` | Primary text |
| `--text-muted` | `#9A958C` | Secondary |
| `--text-faint` | `#6B6760` | Tertiary / hints |
| `--accent` | `#E85D04` | Primary CTA (burnt orange) |
| `--accent-press` | `#C44E03` | Pressed CTA |
| `--gold` | `#E1B46E` | Badges, sync, kind chips |
| `--danger` | `#FF4D6D` | Destructive / errors |
| `--success` | `#3DDC97` | Synced / downloaded |
| `--overlay` | `#00000099` | Scrims |

### Kind badges
| Kind | Label | Bg | Fg |
|------|-------|----|----|
| Ebook | READ | `#2A2A2E` | `#F4F1EA` |
| Audiobook | LISTEN | `#2A2418` | `#E1B46E` |
| Readaloud | SYNC | `#2A1810` | `#E85D04` |
| Podcast | POD | `#18202A` | `#8AB4FF` |

### Reader (in-content only — optional)
- Sepia paper `#F1E5C8` / ink `#2C2416`
- Night paper `#0B0B0C` / ink `#F4F1EA`
- Do not change tab chrome when reader theme changes

## Type
| Role | Size / weight | Notes |
|------|---------------|-------|
| Wordmark | 20–24 / semibold condensed | Header only |
| Screen title | 28 / bold | Large title |
| Card title | 16 / semibold | 2-line clamp |
| Body | 15 / regular | Settings, stats |
| Meta | 13 / regular | Authors, sync time |
| Tab label | 10 / medium | System tab |

Reader body fonts: Silveran-controlled (user fonts, spacing, margins).

## Spacing
- Base grid: **8pt** (half-steps **4pt**)
- Screen horizontal inset: 16
- Card padding: 12–16
- Grid gutter: 12
- Mini-bar height: 56
- Tab bar: system
- Cover radius: 8
- Button radius: 12
- Chip radius: 999 (pill)

## Elevation
- Cards: 1pt border `--border`, no heavy drop shadows
- Mini-bar: top hairline + `--surface`
- Sheets: standard SwiftUI detents

## Icons
- SF Symbols preferred
- Sync: `icloud.and.arrow.up` / `checkmark.icloud`
- Offline: `icloud.slash`
- Tab suggestions: `house`, `books.vertical`, `arrow.down.circle`, `mic`, `chart.bar`

## Motion
- Short (200–280ms) ease for tab / sheet
- Progress ring and sync chip: subtle, not bouncey
- No parallax clutter on Library

## Accessibility
- Contrast ≥ WCAG AA for text on `--bg` / `--surface`
- Dynamic Type: chrome scales; covers stay fixed aspect
- Reduce Motion: disable chart draw animations
- VoiceOver: kind badge + title + progress percent on each card
- Hit targets ≥ 44×44

## Do / Don’t
- DO keep Browse (Library) vs Shelf (downloads) separate
- DO show skeletons while `/api/books` loads
- DO one progress for readaloud across Read | Listen
- DON’T put podcasts in Storyteller kind filters
- DON’T mix tiny line-icon placeholders with photo covers at different visual weight — use consistent 2:3 cover or a single silhouette placeholder
- DON’T redesign Silveran’s reader chrome in v1 — wrap it
```

---

## 4. Component notes for Hermes (SwiftUI)

Implement against SilveranKit / SilveranAppleKit; this is chrome + IA, not a second sync engine.

| Component | Responsibility |
|-----------|----------------|
| `RootTabView` | 5 tabs + optional `MiniPlayerBar` |
| `ConnectServerView` / `SignInView` | URL + token/OPDS auth states from Nas-ty brief |
| `HomeView` | Continue hero, Up next, stats strip, sync chip |
| `LibraryView` | Search, kind chips, cover grid, series derivation |
| `ShelfView` | Downloads only |
| `PodcastsView` | Enve-style feeds (separate store) |
| `StatsView` | Local aggregates |
| `CoverCard` | Shared 2:3 media + kind badge + title/author |
| `KindBadge` | READ / LISTEN / SYNC / POD |
| `SyncChip` | Synced / Syncing / Offline |
| `BookDetailView` | CTA + Read\|Listen for readaloud |
| `MiniPlayerBar` / `NowPlayingView` | Shared for audiobook + podcast + readaloud audio |

### Auth state machine (UI)
`noServer` → `unauthenticated` → `authenticating` → `authenticated` → (`offline` overlay when host unreachable but shelf has items)

### Data assumptions until field dump
- Catalogue list items expose: id, title, authors, cover URL, kind ∈ {ebook, audiobook, readaloud}, series?, progress 0…1, updatedAt  
- Podcasts: separate local model (feed URL, show, episodes)  
- Stats: computed client-side from session log

### Out of scope for shell v1
- tvOS / watch / CarPlay polish  
- Device-code pairing UI (optional later)  
- Full Enve comics pipeline  
- Replacing Silveran readaloud engine

---

## Reader fonts (added 2026-09-14)


## Reader fonts — Fast Font (Born2Root)
Source: https://github.com/Born2Root/Fast-Font/tree/main/fast-fonts  
Open-source speed-reading faces (bionic-style fixation via contextual alternates). Bundle TTFs in the app; expose in Silveran reader Aa / font picker **in addition to** existing Silveran fonts — do not replace system defaults as the only option.

| File | Family (use in UI) | When |
|------|-------------------|------|
| `Fast_Serif.ttf` | Fast Serif | Default long-form ebook / readaloud text (Bookerly-based) |
| `Fast_Sans.ttf` | Fast Sans | Clean sans reading (Inter-based) |
| `Fast_Sans_Dotted.ttf` | Fast Sans Dotted | Space-reading training (dots in word gaps) |
| `Fast_OpenDyslexic.ttf` | Fast OpenDyslexic | Dyslexia-friendly option |
| `Fast_Mono.ttf` | Fast Mono | Optional; code / monospace passages only — not default body |

**Reader settings row:** Font → list Silveran fonts + the five Fast Font entries above.  
**Default for new installs (Josh preference):** Fast Serif for ebook body; Fast Sans as second preset.  
**Note:** Enable OpenType contextual alternates where the engine allows (required for the fixation effect).  
**License:** project is open-source / free to use; keep attribution in Settings → About / Licenses.


## Handoff checklist

- [x] System light + dark chrome (follow iOS)
- [x] Concept & IA  
- [x] Stitch prompt (8 screens)  
- [x] DESIGN.md tokens  
- [x] Hermes component map  
- [ ] Regenerate Stitch after authenticated `/api/v2/books` field dump if cover/series fields differ  
- [ ] Josh locks app display name if not literally `punk+rally`
