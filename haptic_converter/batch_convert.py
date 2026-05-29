"""
batch_convert.py
----------------
Converts a folder of audio files (MP3 / WAV / FLAC / AAC / M4A / OGG) into
Apple CoreHaptics .ahap pattern files using librosa onset detection and
short-time energy analysis.

Usage:
    python3 batch_convert.py <audio_dir/> <output_dir/> [options]

Options:
    --workers N                     Parallel worker threads (default: 2)
    --min-transient-intensity X     Minimum intensity for transient events (default: 0.05)
    --min-continuous-intensity X    Minimum intensity for continuous events (default: 0.10)

Exit codes:
    0  all files converted successfully
    1  one or more files failed (others still attempted)
"""

import argparse
import json
import os
import sys
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

SUPPORTED_EXTENSIONS = {".mp3", ".wav", ".flac", ".aac", ".m4a", ".ogg", ".opus"}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Convert audio files to .ahap haptic patterns.")
    p.add_argument("audio_dir",  type=Path, help="Directory of input audio files")
    p.add_argument("output_dir", type=Path, help="Directory to write .ahap files")
    p.add_argument("--workers",                    type=int,   default=2)
    p.add_argument("--min-transient-intensity",    type=float, default=0.05)
    p.add_argument("--min-continuous-intensity",   type=float, default=0.10)
    return p.parse_args()


def audio_to_ahap(
    audio_path: Path,
    output_dir: Path,
    min_transient: float,
    min_continuous: float,
) -> Path:
    """
    Convert a single audio file → .ahap and return the output path.
    Raises on any error so the caller can log it.
    """
    import librosa
    import numpy as np

    sr_target = 22050          # downsample to save memory on the runner
    hop_length = 512           # ~23 ms per frame at 22 050 Hz

    y, sr = librosa.load(str(audio_path), sr=sr_target, mono=True)
    duration = librosa.get_duration(y=y, sr=sr)

    # ── Transient events: onset detection ────────────────────────────────────
    onset_frames = librosa.onset.onset_detect(
        y=y, sr=sr, hop_length=hop_length,
        backtrack=True, units="frames",
    )
    onset_times    = librosa.frames_to_time(onset_frames, sr=sr, hop_length=hop_length)
    onset_strength = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)

    # Normalise onset strength to [0, 1]
    max_strength = onset_strength.max() if onset_strength.max() > 0 else 1.0
    onset_strength_norm = onset_strength / max_strength

    # ── Continuous events: short-time RMS energy in 100 ms windows ───────────
    frame_len   = int(sr * 0.10)    # 100 ms window
    hop_cont    = int(sr * 0.05)    # 50 ms hop  →  20 events/sec max
    rms         = librosa.feature.rms(y=y, frame_length=frame_len, hop_length=hop_cont)[0]
    rms_norm    = rms / rms.max() if rms.max() > 0 else rms
    cont_times  = librosa.frames_to_time(
        range(len(rms_norm)), sr=sr, hop_length=hop_cont
    )

    # ── Build AHAP pattern list ───────────────────────────────────────────────
    events: list[dict] = []

    # Transient events
    for frame, t in zip(onset_frames, onset_times):
        if t > duration:
            break
        intensity = float(onset_strength_norm[min(frame, len(onset_strength_norm) - 1)])
        if intensity < min_transient:
            continue
        sharpness = min(1.0, intensity * 1.2)   # brighter onsets feel sharper
        events.append({
            "Event": {
                "Time": round(float(t), 4),
                "EventType": "HapticTransient",
                "EventParameters": [
                    {"ParameterID": "HapticIntensity", "ParameterValue": round(intensity, 4)},
                    {"ParameterID": "HapticSharpness", "ParameterValue": round(sharpness, 4)},
                ],
            }
        })

    # Continuous events (one per RMS frame, deduplicated against transients)
    transient_times_set = set(round(float(t), 2) for t in onset_times)
    for t, amp in zip(cont_times, rms_norm):
        if t > duration:
            break
        if float(amp) < min_continuous:
            continue
        t_rounded = round(float(t), 2)
        if t_rounded in transient_times_set:
            continue   # transient already covers this moment
        events.append({
            "Event": {
                "Time": round(float(t), 4),
                "EventType": "HapticContinuous",
                "EventDuration": 0.05,   # one frame length
                "EventParameters": [
                    {"ParameterID": "HapticIntensity", "ParameterValue": round(float(amp), 4)},
                    {"ParameterID": "HapticSharpness", "ParameterValue": 0.3},
                ],
            }
        })

    # Sort by time (continuous + transient may be interleaved)
    events.sort(key=lambda e: e["Event"]["Time"])

    ahap = {
        "Version": 1,
        "Metadata": {
            "Project": "SpotHaptics",
            "Created": datetime.now(timezone.utc).isoformat(),
            "Description": audio_path.stem,
        },
        "Pattern": events,
    }

    out_path = output_dir / (audio_path.stem + ".ahap")
    out_path.write_text(json.dumps(ahap, indent=2), encoding="utf-8")
    return out_path


def main() -> None:
    args = parse_args()

    if not args.audio_dir.is_dir():
        print(f"❌  Audio directory not found: {args.audio_dir}", file=sys.stderr)
        sys.exit(1)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    audio_files = sorted(
        f for f in args.audio_dir.rglob("*")
        if f.is_file() and f.suffix.lower() in SUPPORTED_EXTENSIONS
    )

    if not audio_files:
        print(f"❌  No supported audio files found in: {args.audio_dir}", file=sys.stderr)
        print(f"   Supported: {', '.join(sorted(SUPPORTED_EXTENSIONS))}", file=sys.stderr)
        sys.exit(1)

    print(f"🎵  Found {len(audio_files)} audio file(s) — converting with {args.workers} worker(s) …")
    print()

    failures: list[tuple[Path, str]] = []

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(
                audio_to_ahap,
                f,
                args.output_dir,
                args.min_transient_intensity,
                args.min_continuous_intensity,
            ): f
            for f in audio_files
        }
        for future in as_completed(futures):
            src = futures[future]
            try:
                out = future.result()
                print(f"  ✅  {src.name}  →  {out.name}  ({out.stat().st_size // 1024} KB)")
            except Exception:
                tb = traceback.format_exc().strip().splitlines()[-1]
                print(f"  ❌  {src.name}  FAILED: {tb}")
                failures.append((src, tb))

    print()
    converted = len(audio_files) - len(failures)
    print(f"🎛️   Done: {converted}/{len(audio_files)} converted.")

    if failures:
        print(f"\n⚠️   {len(failures)} file(s) failed:")
        for path, reason in failures:
            print(f"     {path.name}: {reason}")
        sys.exit(1)


if __name__ == "__main__":
    main()
