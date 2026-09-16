# YouTube in-app v1 — Settings + resolve contract

ink+amp can play an episode’s YouTube link **inside** Now Playing on the same shared `AVPlayer` + `PodcastVideoSurfaceView` path as RSS video. No official YouTube SDK / Google sign-in. SponsorBlock-style skip is **Later** (player stays seekable so it can layer on later).

## App setting

**Settings → Podcast Downloads → YouTube resolve URL**

| | |
|---|---|
| Default | `http://192.168.1.2:3000` |
| Meaning | Invidious / Piped-style **base** URL (no `/api/v1` suffix) |
| Test | `GET /api/v1/stats` (Invidious) or `GET /health` (thin NAS) — OK / Timed out / Unreachable |

Env-style name for docs: `YOUTUBE_RESOLVE_URL` (= the same base URL). Point it at home Wi‑Fi Invidious on PrincessDonut (or any compatible host Josh runs).

## Resolve contract

App flow for **Play in ink+amp**:

1. Read video id from the episode’s YouTube watch/share URL (`PodcastYouTubeURL`).
2. Soft overall timeout **~20s** (never hang on Resolving…).
3. Try, in order:
   - `GET {base}/api/v1/videos/{id}` — Invidious
   - `GET {base}/streams/{id}` — Piped
   - `GET {base}/v1/resolve?v={id}` — thin NAS shim `{ "url": "…" }`
4. Pick a playable URL:
   - Prefer progressive muxed **mp4** from `formatStreams` / Piped muxed `videoStreams`
   - Else `hlsUrl` / Piped `hls`
5. Open that URL via existing `AudioSessionActor.openPodcast` with `isVideo=true` (same chrome as RSS video). Scrub / −15 / +15 stay enabled for a future SponsorBlock layer.

**Watch on YouTube** always remains: opens Safari / YouTube app (handoff). Used as the explicit fallback and after resolve failure (toast + handoff).

## Failure modes

| Case | UI |
|---|---|
| Empty / bad Settings URL | Toast · handoff to Watch on YouTube |
| Worker unreachable / HTTP error | Toast · handoff |
| Soft timeout (~20s) | Toast · handoff (no stuck Resolving…) |
| JSON with no progressive/HLS URL | Toast · handoff |
| Audio-only RSS episode (no YouTube) | Unchanged — no YouTube chips |
| RSS video enclosure present | Hybrid path unchanged; YouTube chips hidden (`watchOnYouTubeURL` nil) |

Toast copy: `Couldn't play YouTube · opening app`.

## Out of scope (v1)

- SponsorBlock / mid-roll skip (Later)
- YouTube search / subscriptions / comments
- Downloading YouTube to Shelf
- Official iframe SDK / Google account
- CarPlay / widgets / App Groups

## Smoke (Josh)

1. Settings → YouTube resolve URL → home Invidious → **Test** → OK / Invidious.
2. Open an episode with a YouTube link in notes (no RSS video).
3. **Play in ink+amp** → full NP video surface + seekable scrub.
4. Kill Wi‑Fi or point URL at a dead host → toast + **Watch on YouTube** still works.
