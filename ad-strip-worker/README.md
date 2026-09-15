# ink+amp ad-strip worker

Dumb-cut ffmpeg worker for PrincessDonut. See **`docs/AD_STRIP.md`** for the HTTP contract and NAS deploy steps.

```bash
docker compose up -d --build
curl -fsS http://127.0.0.1:20129/health
```

App: Settings → Podcast Downloads → Ad strip URL = `http://192.168.1.2:20129`
