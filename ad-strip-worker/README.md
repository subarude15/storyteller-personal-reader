# ink+amp ad-strip worker

Dumb-cut + edge silence-trim ffmpeg worker for PrincessDonut. See **`docs/AD_STRIP.md`** for the HTTP contract, env knobs, and NAS deploy steps.

```bash
# Preferred on PrincessDonut:
cd /volume1/docker/inkamp-ad-strip   # or repo ad-strip-worker/
docker compose up -d --build
curl -fsS http://192.168.1.2:20129/health
```

Local smoke: `./selfcheck.sh` (needs ffmpeg + `pip install -r requirements.txt`).

App: Settings → Podcast Downloads → Ad strip URL = `http://192.168.1.2:20129`
