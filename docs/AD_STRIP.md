# Ad-strip worker — HTTP contract + NAS deploy

ink+amp Clean downloads call a LAN worker on **PrincessDonut** (`192.168.1.2`). The app never deletes Original; Clean is a sibling file on-device.

## App setting

**Settings → Podcast Downloads → Ad strip URL**

| | |
|---|---|
| Default | `http://192.168.1.2:20129` |
| Meaning | Worker **base** URL (no `/v1` suffix) |
| Test | `GET /health` — OK / Timed out / Unreachable; success clears offline state |

Env-style name for docs/scripts: `AD_STRIP_URL` (= the same base URL).

## HTTP contract

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Reachability. JSON `{ "ok": true, "service": "inkamp-ad-strip", "mode": "dumb-cut" }` |
| `POST` | `/v1/jobs` | Start a job. **multipart** `file=@audio.mp3` **or** JSON `{ "url": "https://…" }`. → `202` `{ "id", "status": "queued" }` |
| `GET` | `/v1/jobs/{id}` | Poll. `status`: `queued` \| `processing` \| `done` \| `failed` (+ `error`, `audio_url` when done) |
| `GET` | `/v1/jobs/{id}/audio` | Download cleaned MPEG audio when `done` |

App flow: upload Original → poll until `done` / `failed` / soft timeout → write `audio.clean.mp3` beside Original.

Chip mapping: `queued`/`processing` → **Cleaning…**; `done` → **Clean**; failure/timeout → **Clean failed** + toast. Soft overall timeout (~180s) so Cleaning… never hangs.

## Dumb cut (v1)

ffmpeg silence heuristics only — **no OmniRoute / LLM yet** (segment detect is Later; keep free-first `http://192.168.1.2:20128/v1` or `https://omni.banditoburrito.xyz/v1` when that lands; paid prefer `deepseek/deepseek-v4-pro`).

Heuristic: first silence gap in the opening window whose preceding block looks ad-sized (~5–120s) is cut; edge silence trimmed; result re-encoded as mp3.

## Compose path + port (PrincessDonut)

From the repo (or a copy of `ad-strip-worker/` on the NAS):

```bash
cd /path/to/storyteller-personal-reader/ad-strip-worker
docker compose up -d --build
```

| | |
|---|---|
| Compose file | `ad-strip-worker/docker-compose.yml` |
| Host port | **20129** → container `20129` |
| LAN endpoint | `http://192.168.1.2:20129` |
| Health check | `curl -fsS http://192.168.1.2:20129/health` |
| Data volume | Docker volume `ad_strip_data` (`/data` in container) |

Optional env (compose `environment:`): `AD_STRIP_AD_WINDOW`, `AD_STRIP_MIN_AD`, `AD_STRIP_MAX_AD`, `AD_STRIP_SILENCE_NOISE`, `AD_STRIP_SILENCE_DURATION`.

## Smoke

```bash
curl -fsS http://192.168.1.2:20129/health
curl -fsS -F "file=@/path/to/episode.mp3" http://192.168.1.2:20129/v1/jobs
# poll GET /v1/jobs/{id} until done, then GET /v1/jobs/{id}/audio
```

## Caveats

- Dumb cut only — will miss mid-roll ads and non-silence-separated spots.
- Worker must be reachable on home Wi‑Fi; public URL / Cloudflare tunnel is optional later.
- Original download path does **not** need the worker.
- Worker down / timeout → Clean failed + toast; app stays usable on Original.
