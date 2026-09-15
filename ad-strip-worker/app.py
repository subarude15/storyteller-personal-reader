#!/usr/bin/env python3
"""
ink+amp ad-strip worker (dumb cut).

HTTP contract expected by PodcastAdStripHTTPPipeline:
  GET  /health
  POST /v1/jobs          multipart file=…  OR  JSON {"url":"https://…"}
  GET  /v1/jobs/{id}
  GET  /v1/jobs/{id}/audio

Dumb cut = ffmpeg silence heuristics (leading ad-shaped block + edge silence).
OmniRoute / LLM segment detect is Later — keep free-first when that lands.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, request, send_file

PORT = int(os.environ.get("AD_STRIP_PORT", "20129"))
DATA_DIR = Path(os.environ.get("AD_STRIP_DATA", "/data"))
JOB_TTL_SECONDS = int(os.environ.get("AD_STRIP_JOB_TTL", str(6 * 3600)))
# Leading content before a silence gap is treated as ads when within this window.
AD_WINDOW_SECONDS = float(os.environ.get("AD_STRIP_AD_WINDOW", "180"))
MIN_AD_SECONDS = float(os.environ.get("AD_STRIP_MIN_AD", "5"))
MAX_AD_SECONDS = float(os.environ.get("AD_STRIP_MAX_AD", "120"))
SILENCE_NOISE = os.environ.get("AD_STRIP_SILENCE_NOISE", "-35dB")
SILENCE_DURATION = float(os.environ.get("AD_STRIP_SILENCE_DURATION", "0.55"))

app = Flask(__name__)
DATA_DIR.mkdir(parents=True, exist_ok=True)

_lock = threading.Lock()
_jobs: dict[str, "Job"] = {}


@dataclass
class Job:
    id: str
    status: str = "queued"  # queued | processing | done | failed
    error: str | None = None
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    input_path: Path | None = None
    output_path: Path | None = None
    source_name: str = "audio.mp3"
    cut_seconds: float | None = None

    def touch(self) -> None:
        self.updated_at = time.time()

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "id": self.id,
            "status": self.status,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }
        if self.error:
            out["error"] = self.error
        if self.cut_seconds is not None:
            out["cut_seconds"] = self.cut_seconds
        if self.status == "done":
            out["audio_url"] = f"/v1/jobs/{self.id}/audio"
        return out


def _ext_from_name(name: str) -> str:
    ext = Path(name).suffix.lower().lstrip(".")
    if ext in {"mp3", "m4a", "aac", "wav", "ogg", "opus", "mp4"}:
        return ext
    return "mp3"


def _purge_old_jobs() -> None:
    now = time.time()
    with _lock:
        stale = [jid for jid, job in _jobs.items() if now - job.created_at > JOB_TTL_SECONDS]
        for jid in stale:
            job = _jobs.pop(jid, None)
            if job is None:
                continue
            folder = DATA_DIR / jid
            shutil.rmtree(folder, ignore_errors=True)


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=False,
        capture_output=True,
        text=True,
        timeout=600,
    )


def _silence_ends(input_path: Path) -> list[float]:
    """Return silence_end timestamps from ffmpeg silencedetect."""
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-i",
        str(input_path),
        "-af",
        f"silencedetect=noise={SILENCE_NOISE}:d={SILENCE_DURATION}",
        "-f",
        "null",
        "-",
    ]
    proc = _run(cmd)
    text = (proc.stderr or "") + "\n" + (proc.stdout or "")
    ends: list[float] = []
    for match in re.finditer(r"silence_end:\s*([0-9.]+)", text):
        ends.append(float(match.group(1)))
    return ends


def _duration_seconds(input_path: Path) -> float | None:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(input_path),
    ]
    proc = _run(cmd)
    if proc.returncode != 0:
        return None
    try:
        return float((proc.stdout or "").strip())
    except ValueError:
        return None


def _dumb_cut(input_path: Path, output_path: Path) -> float:
    """
    Heuristic:
    1) Find first silence_end in the ad window whose preceding segment looks ad-sized.
    2) Cut from that point and re-encode to mp3 for a stable Clean sibling.
    3) If no ad-shaped gap, still re-encode so Clean is a real processed file.
    Returns seconds cut from the start (0 if none).
    """
    ends = _silence_ends(input_path)
    cut_at = 0.0
    for end in ends:
        if end > AD_WINDOW_SECONDS:
            break
        if MIN_AD_SECONDS <= end <= MAX_AD_SECONDS:
            cut_at = end
            break

    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-i",
        str(input_path),
    ]
    if cut_at > 0:
        cmd += ["-ss", f"{cut_at:.3f}"]
    cmd += [
        "-c:a",
        "libmp3lame",
        "-q:a",
        "4",
        str(output_path),
    ]
    proc = _run(cmd)
    if proc.returncode != 0 or not output_path.exists() or output_path.stat().st_size < 256:
        # Fallback: stream-copy-ish re-encode without seek (still never delete Original).
        if output_path.exists():
            output_path.unlink(missing_ok=True)
        fallback = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-i",
            str(input_path),
            "-c:a",
            "libmp3lame",
            "-q:a",
            "4",
            str(output_path),
        ]
        proc2 = _run(fallback)
        if proc2.returncode != 0 or not output_path.exists() or output_path.stat().st_size < 256:
            raise RuntimeError(
                f"ffmpeg failed (code={proc.returncode}): {(proc.stderr or '')[-800:]}"
            )
        return 0.0
    return cut_at


def _download_url(url: str, dest: Path) -> None:
    # Prefer curl for redirects / large files without pulling extra Python deps.
    proc = _run(["curl", "-fsSL", "--max-time", "300", "-o", str(dest), url])
    if proc.returncode != 0 or not dest.exists() or dest.stat().st_size < 256:
        raise RuntimeError(f"download failed: {(proc.stderr or proc.stdout or '')[-400:]}")


def _process_job(job_id: str) -> None:
    with _lock:
        job = _jobs.get(job_id)
        if job is None:
            return
        job.status = "processing"
        job.touch()
        input_path = job.input_path
        folder = DATA_DIR / job_id

    assert input_path is not None
    output_path = folder / "clean.mp3"
    try:
        cut = _dumb_cut(input_path, output_path)
        with _lock:
            job = _jobs.get(job_id)
            if job is None:
                return
            job.output_path = output_path
            job.cut_seconds = cut
            job.status = "done"
            job.touch()
    except Exception as exc:  # noqa: BLE001 — surface any strip failure to the client
        with _lock:
            job = _jobs.get(job_id)
            if job is None:
                return
            job.status = "failed"
            job.error = str(exc)[:500]
            job.touch()


def _enqueue(job: Job) -> None:
    with _lock:
        _jobs[job.id] = job
    thread = threading.Thread(target=_process_job, args=(job.id,), daemon=True)
    thread.start()


@app.get("/health")
def health() -> Any:
    _purge_old_jobs()
    ffmpeg_ok = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
    return jsonify(
        {
            "ok": ffmpeg_ok,
            "service": "inkamp-ad-strip",
            "mode": "dumb-cut",
            "ffmpeg": ffmpeg_ok,
        }
    )


@app.post("/v1/jobs")
def create_job() -> Any:
    _purge_old_jobs()
    job_id = uuid.uuid4().hex
    folder = DATA_DIR / job_id
    folder.mkdir(parents=True, exist_ok=True)

    source_name = "audio.mp3"
    input_path = folder / f"original.{_ext_from_name(source_name)}"

    if "file" in request.files:
        upload = request.files["file"]
        source_name = upload.filename or source_name
        input_path = folder / f"original.{_ext_from_name(source_name)}"
        upload.save(input_path)
    else:
        payload = request.get_json(silent=True) or {}
        url = (payload.get("url") or request.form.get("url") or "").strip()
        if not url:
            shutil.rmtree(folder, ignore_errors=True)
            return jsonify({"error": "Provide multipart file=… or JSON {\"url\":\"…\"}"}), 400
        source_name = Path(url.split("?", 1)[0]).name or source_name
        input_path = folder / f"original.{_ext_from_name(source_name)}"
        try:
            _download_url(url, input_path)
        except Exception as exc:  # noqa: BLE001
            shutil.rmtree(folder, ignore_errors=True)
            return jsonify({"error": str(exc)[:500]}), 400

    if not input_path.exists() or input_path.stat().st_size < 256:
        shutil.rmtree(folder, ignore_errors=True)
        return jsonify({"error": "empty or missing input audio"}), 400

    job = Job(id=job_id, input_path=input_path, source_name=source_name, status="queued")
    _enqueue(job)
    return jsonify(job.to_dict()), 202


@app.get("/v1/jobs/<job_id>")
def get_job(job_id: str) -> Any:
    with _lock:
        job = _jobs.get(job_id)
        if job is None:
            return jsonify({"error": "not found"}), 404
        return jsonify(job.to_dict())


@app.get("/v1/jobs/<job_id>/audio")
def get_audio(job_id: str) -> Any:
    with _lock:
        job = _jobs.get(job_id)
        if job is None:
            return jsonify({"error": "not found"}), 404
        if job.status != "done" or job.output_path is None:
            return jsonify({"error": "audio not ready", "status": job.status}), 409
        path = job.output_path
    return send_file(
        path,
        mimetype="audio/mpeg",
        as_attachment=True,
        download_name=f"{job_id}.clean.mp3",
    )


def main() -> None:
    app.run(host="0.0.0.0", port=PORT, threaded=True)


if __name__ == "__main__":
    main()
