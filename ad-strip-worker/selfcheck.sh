#!/usr/bin/env bash
# ponytail: local smoke for dumb-cut worker (fails if health/job/audio break).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${AD_STRIP_PORT:-20129}"
DATA="${AD_STRIP_DATA:-/tmp/inkamp-ad-strip-selfcheck}"
FIX="${TMPDIR:-/tmp}/inkamp-ad-strip-fixture.mp3"
rm -rf "$DATA"
mkdir -p "$DATA"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=8" \
  -f lavfi -i "anullsrc=r=44100:cl=mono:d=1" \
  -f lavfi -i "sine=frequency=880:duration=4" \
  -filter_complex "[0][1][2]concat=n=3:v=0:a=1" "$FIX"
cd "$ROOT"
AD_STRIP_DATA="$DATA" AD_STRIP_PORT="$PORT" python3 - <<PY
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
assert json.load(urllib.request.urlopen(base + "/health", timeout=5))["ok"]
fix = os.environ.get("FIX", "${FIX}")
job = json.loads(subprocess.check_output(
    ["curl", "-fsS", "-F", f"file=@{fix}", base + "/v1/jobs"], text=True
))
jid = job["id"]
for _ in range(60):
    st = json.load(urllib.request.urlopen(f"{base}/v1/jobs/{jid}", timeout=5))
    if st["status"] in ("done", "failed"):
        break
    time.sleep(0.4)
assert st["status"] == "done", st
subprocess.check_call(["curl", "-fsS", "-o", "/tmp/inkamp-ad-strip-clean.mp3", f"{base}/v1/jobs/{jid}/audio"])
print("SELFCHECK_OK", st.get("cut_seconds"))
PY
