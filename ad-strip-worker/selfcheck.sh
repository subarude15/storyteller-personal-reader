#!/usr/bin/env bash
# ponytail: local smoke for dumb-cut + edge silence-trim (fails if health/job/audio break).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${AD_STRIP_PORT:-20129}"
DATA="${AD_STRIP_DATA:-/tmp/inkamp-ad-strip-selfcheck}"
FIX="${TMPDIR:-/tmp}/inkamp-ad-strip-fixture.mp3"
QUIET="${TMPDIR:-/tmp}/inkamp-ad-strip-quiet-intro.mp3"
rm -rf "$DATA"
mkdir -p "$DATA"

# Fixture A: 8s tone | 1s silence | 4s tone  → ad-shaped leading block cut.
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=8" \
  -f lavfi -i "anullsrc=r=44100:cl=mono:d=1" \
  -f lavfi -i "sine=frequency=880:duration=4" \
  -filter_complex "[0][1][2]concat=n=3:v=0:a=1" "$FIX"

# Fixture B: 3s leading silence | 5s tone | 3s trailing silence → edge trim only.
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "anullsrc=r=44100:cl=mono:d=3" \
  -f lavfi -i "sine=frequency=660:duration=5" \
  -f lavfi -i "anullsrc=r=44100:cl=mono:d=3" \
  -filter_complex "[0][1][2]concat=n=3:v=0:a=1" "$QUIET"

cd "$ROOT"
AD_STRIP_DATA="$DATA" AD_STRIP_PORT="$PORT" FIX="$FIX" QUIET="$QUIET" python3 - <<'PY'
import json, os, subprocess, sys, threading, time, urllib.request
sys.path.insert(0, ".")
from app import app

port = int(os.environ["AD_STRIP_PORT"])
threading.Thread(
    target=lambda: app.run(host="127.0.0.1", port=port, threaded=True, use_reloader=False),
    daemon=True,
).start()
time.sleep(1.0)
base = f"http://127.0.0.1:{port}"
health = json.load(urllib.request.urlopen(base + "/health", timeout=5))
assert health["ok"] and health.get("mode") == "dumb-cut", health
assert health.get("edge_trim") is True, health


def run_job(path: str) -> dict:
    job = json.loads(subprocess.check_output(
        ["curl", "-fsS", "-F", f"file=@{path}", base + "/v1/jobs"], text=True
    ))
    jid = job["id"]
    st = None
    for _ in range(60):
        st = json.load(urllib.request.urlopen(f"{base}/v1/jobs/{jid}", timeout=5))
        if st["status"] in ("done", "failed"):
            break
        time.sleep(0.4)
    assert st and st["status"] == "done", st
    subprocess.check_call(
        ["curl", "-fsS", "-o", f"/tmp/inkamp-ad-strip-{jid}.mp3", f"{base}/v1/jobs/{jid}/audio"]
    )
    return st


ad = run_job(os.environ["FIX"])
assert (ad.get("cut_seconds") or 0) >= 5, ad

quiet = run_job(os.environ["QUIET"])
# Quiet intro (< MIN_AD) should edge-trim lead; trail silence should trim too.
assert (quiet.get("lead_trim_seconds") or 0) >= 1.5, quiet
assert (quiet.get("trail_trim_seconds") or 0) >= 1.5, quiet

print("SELFCHECK_OK", "ad_cut=", ad.get("cut_seconds"),
      "quiet_lead=", quiet.get("lead_trim_seconds"),
      "quiet_trail=", quiet.get("trail_trim_seconds"))
PY
