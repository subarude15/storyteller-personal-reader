# Podcasts — Shelf auto-prune (UX note for Smokey)

**Goal:** Stop half-listened / abandoned downloads from filling Shelf. Personal-only; defaults should be forgiving, not aggressive.

## Where it lives
**Settings → Podcasts → Downloads** (not buried in Shelf overflow). Shelf can show a one-line footer when prune last ran: `Pruned 3 episodes · Settings`.

## Recommended default policy (ship this)
Combine **finished** + **age**, with a **progress floor** so “started but abandoned” clears and “almost done” stays.

| Rule | Default | Behavior |
|------|---------|----------|
| Delete when finished | **On** | Progress ≥ 95% (or player “mark finished”) → remove download after next successful sync/close of episode (or overnight job) |
| Keep unfinished if progress ≥ | **10%** | Below 10% counts as “barely started” for age prune; at/above 10% protect from age prune unless max-age hit |
| Max age on device | **30 days** since download (or last play, whichever later) | Older downloads deleted unless pinned |
| Max episodes kept | **50** total downloaded podcasts | When over cap, delete oldest by last-play (then download date), skipping pinned + in-progress (≥10% and &lt;95%) |
| Pin | Manual | Long-press / episode menu → **Keep** — never auto-pruned |

**Default one-liner for Settings:**  
`Auto-remove finished episodes and anything older than 30 days (keeps pinned + in-progress).`

## Controls (simple, Nick-brain)
1. Toggle: **Auto-clean downloads** (default On)
2. When On, three rows:
   - **Remove when finished** (toggle, default On)
   - **Max age** — Off / 7 / 14 / **30** / 90 days
   - **Max downloads** — Off / 25 / **50** / 100
3. Advanced (disclosure): **Protect if played at least** — 0% / **10%** / 25% / 50%
4. Button: **Clean now** → confirmation sheet listing what would be removed (title + reason: Finished / Aged out / Over limit)

## What NOT to do
- Don’t silent-delete without the Settings summary + optional Clean-now preview the first time Auto-clean turns On (one-time explainer sheet)
- Don’t prune audiobook/ebook Shelf downloads with the same knobs — **Podcasts only** unless Josh later asks for a shared policy
- Don’t block IPA / icon / Settings sheet on silence-trim or AI ad-strip (those stay async post-download)

## Copy chips on Shelf rows (optional)
- `Expires in 3d` when within 3 days of max age
- `Finished · removing…` briefly after finish if “Remove when finished” is on

## Acceptance
- Defaults never wipe a pinned show
- Episode at 40% played, 10 days old, under cap → **kept**
- Episode at 2% played, 35 days old → **pruned** (age)
- Episode at 98% → **pruned** when finished rule on
- Over 50 downloads → oldest eligible removed until ≤50

## Out of scope here
Silence trim, AI ad/sponsor strip (OmniRoute/NAS pipeline later).
