# DESIGN.md — punk+rally Reader (iOS)

## Brand
- Name: punk+rally (library OPDS: "punk+rally books")
- Voice: short, cellar-quiet, no corporate fluff
- Platform: iOS first (Cursor iOS / phone); SwiftUI

## Appearance (app chrome)

**Default:** follow iOS system appearance (`UIUserInterfaceStyle` / SwiftUI `@Environment(\.colorScheme)`).  
**Not** dark-only. Library, tabs, Home, Shelf, Podcasts, Stats, Settings, sheets, and mini-bar all use the **chrome** palette for the active scheme.

| Preference | Behavior |
|------------|----------|
| System (default) | Light chrome in Light Mode; dark chrome in Dark Mode |
| Optional Settings override | System / Light / Dark (standard iOS pattern) |

**Reader body themes** (Night / Sepia / Paper) are **separate** — they only tint the in-book page. They must **not** flip tab bar, nav, or library chrome.

Shared accents (both schemes):
| Token | Hex | Use |
|-------|-----|-----|
| `--accent` | `#E85D04` | Primary CTA (burnt orange) |
| `--accent-press` | `#C44E03` | Pressed CTA |
| `--gold` | `#E1B46E` | Badges, sync, kind chips |
| `--danger` | `#FF4D6D` | Destructive / errors |
| `--success` | `#3DDC97` | Synced / downloaded |

### Dark chrome (system Dark)

| Token | Hex | Use |
|-------|-----|-----|
| `--bg` | `#0B0B0C` | App background |
| `--surface` | `#161618` | Cards, sheets |
| `--surface-2` | `#1E1E22` | Elevated / pressed |
| `--border` | `#2A2A2E` | Hairlines |
| `--text` | `#F4F1EA` | Primary text |
| `--text-muted` | `#9A958C` | Secondary |
| `--text-faint` | `#6B6760` | Tertiary / hints |
| `--overlay` | `#00000099` | Scrims |
| `--tab-active` | `#E85D04` | Selected tab |
| `--mini-bar` | `#161618` | Mini-player surface |

### Light chrome (system Light)

| Token | Hex | Use |
|-------|-----|-----|
| `--bg` | `#F7F5F2` | App background (warm paper white, not pure #FFF) |
| `--surface` | `#FFFFFF` | Cards, sheets |
| `--surface-2` | `#EFEAE4` | Elevated / pressed / chip wells |
| `--border` | `#E0DAD2` | Hairlines |
| `--text` | `#1A1814` | Primary text |
| `--text-muted` | `#6B6560` | Secondary |
| `--text-faint` | `#9A948C` | Tertiary / hints |
| `--overlay` | `#00000066` | Scrims |
| `--tab-active` | `#E85D04` | Selected tab |
| `--mini-bar` | `#FFFFFF` | Mini-player surface (+ top hairline `--border`) |

Light mode still uses `--accent` / `--gold` unchanged. Avoid pure gray-on-white; keep the warm paper tint so it stays punk+rally, not generic iOS gray.

### Kind badges

**Dark chrome**
| Kind | Label | Bg | Fg |
|------|-------|----|----|
| Ebook | READ | `#2A2A2E` | `#F4F1EA` |
| Audiobook | LISTEN | `#2A2418` | `#E1B46E` |
| Readaloud | SYNC | `#2A1810` | `#E85D04` |
| Podcast | POD | `#18202A` | `#8AB4FF` |

**Light chrome**
| Kind | Label | Bg | Fg |
|------|-------|----|----|
| Ebook | READ | `#EFEAE4` | `#1A1814` |
| Audiobook | LISTEN | `#F5EDD8` | `#8A6A2A` |
| Readaloud | SYNC | `#FCE8D8` | `#C44E03` |
| Podcast | POD | `#E4EEF8` | `#2F5F9A` |

### Reader (in-content only — optional overrides)
These change **book page** only. Tab bar / library stay on system chrome.

| Theme | Paper | Ink |
|-------|-------|-----|
| Night | `#0B0B0C` | `#F4F1EA` |
| Sepia | `#F1E5C8` | `#2C2416` |
| Paper | `#FFFEFA` | `#1A1814` |

Default reader page when unset: match system (Light → Paper, Dark → Night) until user picks an Aa override.

## Reader fonts — Fast Font (Born2Root)
Source: https://github.com/Born2Root/Fast-Font/tree/main/fast-fonts  
Open-source speed-reading faces (bionic-style fixation via contextual alternates). Bundle TTFs; expose in Silveran Aa picker **in addition to** existing fonts.

| File | Family (use in UI) | When |
|------|-------------------|------|
| `Fast_Serif.ttf` | Fast Serif | **Default** long-form ebook / readaloud body |
| `Fast_Sans.ttf` | Fast Sans | Clean sans reading |
| `Fast_Sans_Dotted.ttf` | Fast Sans Dotted | Space-reading training |
| `Fast_OpenDyslexic.ttf` | Fast OpenDyslexic | Dyslexia-friendly |
| `Fast_Mono.ttf` | Fast Mono | Code / mono passages only |

Enable OpenType contextual alternates where possible. Attribution in Settings → Licenses.

## Type
| Role | Size / weight | Notes |
|------|---------------|-------|
| Wordmark | 20–24 / semibold condensed | Header only |
| Screen title | 28 / bold | Large title |
| Card title | 16 / semibold | 2-line clamp |
| Body | 15 / regular | Settings, stats |
| Meta | 13 / regular | Authors, sync time |
| Tab label | 10 / medium | System tab |

UI chrome: SF Pro. Reader body: Fast Serif default (Silveran + Fast Font list).

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
- **Dark:** 1pt border `--border`, no heavy shadows
- **Light:** 1pt border `--border`; optional soft shadow `0 1 2 rgba(0,0,0,0.06)` on cards only
- Mini-bar: top hairline + `--mini-bar`
- Sheets: standard SwiftUI detents

## Icons
- SF Symbols preferred
- Sync: `icloud.and.arrow.up` / `checkmark.icloud`
- Offline: `icloud.slash`
- Tabs: `house`, `books.vertical`, `arrow.down.circle`, `mic`, `chart.bar`

## Motion
- Short (200–280ms) ease for tab / sheet
- Appearance changes follow system (no custom flash)
- Reduce Motion: disable chart draw animations

## Accessibility
- Contrast ≥ WCAG AA on **both** chrome schemes
- Dynamic Type: chrome scales; covers fixed aspect
- VoiceOver: kind badge + title + progress on each card
- Hit targets ≥ 44×44

## Do / Don’t
- DO follow system appearance for all app chrome by default
- DO keep Browse (Library) vs Shelf (downloads) separate
- DO show skeletons while `/api/books` loads
- DO one progress for readaloud across Read | Listen
- DO keep Fast Serif as default reader body
- DON’T make the whole app dark-only
- DON’T let reader Night/Sepia/Paper recolor the tab bar
- DON’T put podcasts in Storyteller kind filters
- DON’T redesign Silveran’s reader engine in v1 — wrap it
