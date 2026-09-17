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
| `GET` | `/health` | Reachability. JSON `{ "ok": true, "service": "inkamp-ad-strip", "mode": "dumb-cut", "edge_trim": true }` |
| `POST` | `/v1/jobs` | Start a job. **multipart** `file=@audio.mp3` **or** JSON `{ "url": "https://…" }`. → `202` `{ "id", "status": "queued" }` |
| `GET` | `/v1/jobs/{id}` | Poll. `status`: `queued` \| `processing` \| `done` \| `failed` (+ `error`, `audio_url` when done; optional `cut_seconds` / `lead_trim_seconds` / `trail_trim_seconds`) |
| `GET` | `/v1/jobs/{id}/audio` | Download cleaned MPEG audio when `done` |

App flow: upload Original → poll until `done` / `failed` / soft timeout → write `audio.clean.mp3` beside Original.

Chip mapping: `queued`/`processing` → **Cleaning…**; `done` → **Clean**; failure/timeout → **Clean failed** + toast. Soft overall timeout (~180s) so Cleaning… never hangs. Cleaning… is a job chip (not episode remaining).

## Dumb cut + silence-trim (v1)

ffmpeg silence heuristics only — **no OmniRoute / LLM yet** (segment detect is Later; keep free-first `http://192.168.1.2:20128/v1` or `https://omni.banditoburrito.xyz/v1` when that lands; paid prefer `deepseek/deepseek-v4-pro`).

Pipeline (always part of Clean output when edge trim is on — default):

1. **Leading ad-shaped block** — first silence gap whose preceding block looks ad-sized (~5–120s) is cut at `silence_end`.
2. **Edge silence-trim** — leading + trailing quiet (capped) so quiet-intro episodes start closer to speech; trailing outro hush is shaved too.
3. Re-encode as mp3 for a stable Clean sibling.

Disable edge trim only (keep ad cut): `AD_STRIP_EDGE_TRIM=0`.

## Compose path + port (PrincessDonut)

Preferred NAS directory: **`/volume1/docker/inkamp-ad-strip`** (copy of repo `ad-strip-worker/`). Image is **Alpine + apk ffmpeg** (avoid debian `apt-get` on Synology — prior hang).

```bash
# On JoshNuc (SSH to NAS with id_ed25519_nas), then:
cd /volume1/docker/inkamp-ad-strip   # or: …/storyteller-personal-reader/ad-strip-worker
docker compose up -d --build
curl -fsS http://192.168.1.2:20129/health
# expect: {"ok":true,"service":"inkamp-ad-strip","mode":"dumb-cut","edge_trim":true,...}
```

| | |
|---|---|
| Compose file | `ad-strip-worker/docker-compose.yml` |
| Host port | **20129** → container `20129` |
| LAN endpoint | `http://192.168.1.2:20129` |
| Health check | `curl -fsS http://192.168.1.2:20129/health` |
| Data volume | Docker volume `ad_strip_data` (`/data` in container) |

Optional env (compose `environment:`):

| Env | Default | Meaning |
|---|---|---|
| `AD_STRIP_AD_WINDOW` | `180` | Max seconds to look for a leading ad gap |
| `AD_STRIP_MIN_AD` / `AD_STRIP_MAX_AD` | `5` / `120` | Preceding-block size treated as ads |
| `AD_STRIP_SILENCE_NOISE` | `-35dB` | silencedetect noise floor |
| `AD_STRIP_SILENCE_DURATION` | `0.55` | Min silence length (seconds) |
| `AD_STRIP_MAX_EDGE_TRIM` | `8` | Max seconds trimmed from each edge |
| `AD_STRIP_EDGE_TRIM` | `1` | `0` / `false` / `off` disables edge trim |

## Smoke

```bash
curl -fsS http://192.168.1.2:20129/health
curl -fsS -F "file=@/path/to/quiet-intro-episode.mp3" http://192.168.1.2:20129/v1/jobs
# poll GET /v1/jobs/{id} until done (check lead_trim_seconds / trail_trim_seconds), then GET /v1/jobs/{id}/audio
```

## Caveats

- Dumb cut only — will miss mid-roll ads and non-silence-separated spots.
- Worker must be reachable on home Wi‑Fi; public URL / Cloudflare tunnel is optional later.
- Original download path does **not** need the worker.
- Worker down / timeout → Clean failed + toast; app stays usable on Original.
- Silence-trim is part of this Clean pipeline; leave ROADMAP **Shipped** flip until Josh verifies on NAS.
