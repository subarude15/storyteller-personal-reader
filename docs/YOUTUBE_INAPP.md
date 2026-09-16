# YouTube in-app v1 — Settings + resolve contract

ink+amp can play an episode’s YouTube link **inside** Now Playing on the same shared `AVPlayer` + `PodcastVideoSurfaceView` path as RSS video. No official YouTube SDK / Google sign-in. SponsorBlock-style skip is **Later** (player stays seekable so it can layer on later).

## App setting

**Settings → Podcast Downloads → YouTube resolve URL**

| | |
|---|---|
| Default | `http://192.168.1.2:20130` |
| Meaning | Invidious / Piped-style **base** URL (no `/api/v1` suffix) |
| Test | `GET /api/v1/stats` (Invidious) or `GET /health` (thin NAS) — OK / Timed out / Unreachable |

Env-style name for docs: `YOUTUBE_RESOLVE_URL` (= the same base URL). Point it at home Wi‑Fi Invidious on PrincessDonut (or any compatible host Josh runs). Josh’s LAN Invidious: `http://192.168.1.2:20130`.

## RSS extract (video id only)

`PodcastYouTubeURL.extract` only accepts URLs that parse a **video id**:

- Accepted: `watch?v=`, `youtu.be/`, `/embed/`, `/shorts/`, `/live/`
- Rejected: channel pages, `@handle`, `/user/`, `/c/`, `/playlist` without `v=`

Scan order for feed candidates: item **link** → **media:player** → enclosures → show notes (`content:encoded` / summary / iTunes). First *valid video* URL wins — a channel URL earlier in the list must not beat a watch URL later.

**Play in ink+amp** / **Watch on YouTube** chips show only when `videoID != nil` (via `watchOnYouTubeURL`, including a user-confirmed Match). Channel-only / no-YouTube feeds get **Match on YouTube** instead of fake Play chips.

## Match on YouTube (v1)

For episodes with **no** confirmed watch URL (and no RSS video enclosure):

1. Episode sheet / full Now Playing (not mini) shows **Match on YouTube**.
2. Tap → soft timeout (~12–20s) → `GET {YOUTUBE_RESOLVE_URL}/api/v1/search?q={showTitle}+{episodeTitle}&type=video`.
3. Confirm sheet lists top ~5 hits (title, author, duration / thumb when present). User picks one — **never auto-pick**.
4. On pick → persist watch URL per episode (`PodcastMatchedYouTubeStore`) → reuse resolve + **Play in ink+amp** (video id → stream → AVPlayer). **Watch on YouTube** appears for the chosen id.
5. Next open: normal Play / Watch chips (no re-search).
6. Failures → toast, no hang. Empty → “No matches”.

Out of scope: auto-match without confirm, SponsorBlock, downloading YouTube, changing extract rules.

## Resolve contract

App flow for **Play in ink+amp**:

1. Button shows **Resolving…** (disabled) until resolve finishes.
2. Read video id from the episode’s YouTube watch/share URL (`PodcastYouTubeURL`) or Match store.
3. Soft overall timeout **~20s** (never hang on Resolving…).
4. Try, in order:
   - `GET {base}/api/v1/videos/{id}` — Invidious
   - `GET {base}/streams/{id}` — Piped
   - `GET {base}/v1/resolve?v={id}` — thin NAS shim `{ "url": "…" }`
5. Pick a playable URL:
   - Prefer progressive muxed **mp4** from `formatStreams` / Piped muxed `videoStreams`
   - Else `hlsUrl` / Piped `hls`
6. Open that URL via existing `AudioSessionActor.openPodcast` with `isVideo=true` (same chrome as RSS video). Scrub / −15 / +15 stay enabled for a future SponsorBlock layer.

On failure: toast + handoff to Watch on YouTube. **Watch on YouTube** stays instant (opens Safari / YouTube app; no resolve).

## Failure modes

| Case | UI |
|---|---|
| Empty / bad Settings URL | Toast · handoff to Watch on YouTube (Play) / search toast (Match) |
| Worker unreachable / HTTP error | Toast · handoff (Play) / “Couldn't search YouTube” (Match) |
| Soft timeout (~20s) | Toast · no stuck Resolving… / Searching… |
| JSON with no progressive/HLS URL | Toast · handoff |
| Search returns zero videos | Sheet “No matches” + toast |
| Audio-only RSS episode (no YouTube) | **Match on YouTube** |
| Channel / @handle only (no video id) | **Match on YouTube** (no fake Play / Watch) |
| RSS video enclosure present | Hybrid path unchanged; YouTube / Match hidden (`watchOnYouTubeURL` nil / `needsYouTubeMatch` false) |

Toast copy:

- Play resolve fail: `Couldn't play YouTube · opening app`
- Match search fail: `Couldn't search YouTube`
- Match empty: `No matches`

## Out of scope (v1)

- Auto-match without confirm
- SponsorBlock / mid-roll skip (Later)
- YouTube subscriptions / comments
- Downloading YouTube to Shelf
- Official iframe SDK / Google account
- CarPlay / widgets / App Groups
- SponsorBlock-style skip

## Playhead (local + Storyteller sync)

In-app YouTube (feed watch URL or Match) persists playhead keyed by **video id** (`YouTubePlayheadStore`), sibling of `PodcastPlayheadStore`:

- Persist periodically (~15s while playing) + on pause / interrupt / scrub / background / card dismiss / end
- Near-end (≥95%) writes a cleared tombstone (next open starts fresh / Continue drops; sync won’t resurrect older mid-episode)
- Reopen / Play in ink+amp / Home Continue seeks to saved playhead (Loading… until playhead advances)
- Episode / show title remembered on the entry for Continue rails
- **Cross-device:** private Storyteller collection `.inkamp.youtubePlayheads.v1` (same auth as Stats); LWW per video id; pull on foreground / before Play; push after persist; Settings → YouTube playheads last-sync. Offline Continue still uses local.

## Smoke (Josh)

1. Settings → YouTube resolve URL → home Invidious (`http://192.168.1.2:20130`) → **Test** → OK / Invidious.
2. Open an episode with a real watch URL (e.g. `https://youtu.be/iURXlAXLIVA`) in notes (no RSS video).
3. **Play in ink+amp** → **Resolving…** then full NP video surface + seekable scrub (must **not** jump straight to the YouTube channel).
4. Channel-only / Vergecast-style episode → **Match on YouTube** (no Play / Watch until confirm).
5. Match → confirm a hit (e.g. Shrek / a Vergecast ep) → Play in ink+amp + Watch on YouTube; reopen shows chips without re-search.
6. **Playhead:** scrub Cult of Shrek / leave / reopen → resumes near leave point; Home Continue shows Xm left and continues correctly.
7. **Playhead sync:** leave mid-episode on phone; open same matched ep on iPad (or reinstall) after sync → resumes near that playhead. Settings → YouTube playheads shows Synced / Offline · local only.
8. Kill Wi‑Fi or point URL at a dead host → toast; Match does not hang.
