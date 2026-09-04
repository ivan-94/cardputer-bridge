#!/usr/bin/env python3
"""Capture final Core Audio output and correlate silence with all gap counters."""

from __future__ import annotations

import argparse
from array import array
import json
from pathlib import Path
import subprocess
import time
from typing import Any

from analyze_audio_continuity import silence_runs
from verify_audio_hil import (
    click_app_microphone_toggle,
    ensure_microphone_muted,
    read_probe,
    wait_for_audio_session_ready,
    wait_for_mic_intent,
)


def integer(probe: dict[str, Any], key: str) -> int:
    value = probe.get(key)
    return int(value) if value is not None else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--consumer",
        default=str(
            Path.home()
            / "Applications/Cardputer Audio Verifier.app/Contents/MacOS/audio_pcm_consumer"
        ),
    )
    parser.add_argument(
        "--macos-probe",
        default=str(
            Path.home()
            / ".local/share/cardputer-bridge/runtime/macos-state.json"
        ),
    )
    parser.add_argument(
        "--audio-probe",
        default=str(
            Path.home()
            / ".local/share/cardputer-bridge/runtime/audio-state.json"
        ),
    )
    parser.add_argument("--capture", type=Path, default=Path("/tmp/cardputer-continuity.f32le"))
    parser.add_argument("--metrics", type=Path, default=Path("/tmp/cardputer-continuity-metrics.json"))
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument(
        "--already-live",
        action="store_true",
        help=(
            "measure an externally-started live session without using macOS "
            "UI automation or changing microphone intent"
        ),
    )
    parser.add_argument("--minimum-hole-ms", type=float, default=1.0)
    parser.add_argument("--maximum-hole-ms", type=float, default=50.0)
    parser.add_argument("--maximum-total-hole-ms", type=float, default=100.0)
    args = parser.parse_args()

    probe_path = Path(args.macos_probe)
    audio_probe_path = Path(args.audio_probe)
    frames = round(args.seconds * 48_000)
    live = False
    before: dict[str, Any] = {}
    audio_before: dict[str, Any] = {}
    try:
        if args.already_live:
            wait_for_mic_intent(probe_path, "live")
        else:
            wait_for_audio_session_ready(probe_path)
            click_app_microphone_toggle()
            live = True
            wait_for_mic_intent(probe_path, "live")
        time.sleep(1.0)
        before = read_probe(probe_path)
        audio_before = read_probe(audio_probe_path)
        subprocess.run(
            [
                args.consumer,
                "--capture-name",
                "Cardputer Microphone",
                "--frames",
                str(frames),
                "--raw",
                str(args.capture),
                "--metrics",
                str(args.metrics),
            ],
            check=True,
        )
    finally:
        if live and not args.already_live:
            ensure_microphone_muted(probe_path)

    time.sleep(1.0)
    after = read_probe(probe_path)
    audio_after = read_probe(audio_probe_path)
    samples = array("f")
    samples.frombytes(args.capture.read_bytes())
    minimum_samples = round(48_000 * args.minimum_hole_ms / 1_000)
    holes = [
        (start, end)
        for start, end in silence_runs(samples, threshold=1e-8)
        if end - start >= minimum_samples
    ]
    durations = [(end - start) * 1_000 / 48_000 for start, end in holes]
    driver_metrics = json.loads(args.metrics.read_text(encoding="utf-8"))
    result = {
        "duration_seconds": len(samples) / 48_000,
        "peak": max(map(abs, samples), default=0.0),
        "hole_count": len(holes),
        "maximum_hole_ms": max(durations, default=0.0),
        "total_hole_ms": sum(durations),
        "maximum_capture_gap_ms": integer(after, "maximum_capture_gap_ms"),
        "maximum_transport_gap_ms": integer(after, "maximum_transport_gap_ms"),
        "maximum_receive_gap_ms": audio_after.get("maximum_receive_gap_ms", 0),
        "receive_gap_over_100ms_growth": integer(
            audio_after, "receive_gap_over_100ms_count"
        ) - integer(audio_before, "receive_gap_over_100ms_count"),
        "receive_gap_over_200ms_growth": integer(
            audio_after, "receive_gap_over_200ms_count"
        ) - integer(audio_before, "receive_gap_over_200ms_count"),
        "accepted_packet_growth": integer(audio_after, "accepted_packets")
        - integer(audio_before, "accepted_packets"),
        "missing_packet_growth": integer(audio_after, "missing_packets")
        - integer(audio_before, "missing_packets"),
        "recovered_packet_growth": integer(audio_after, "recovered_packets")
        - integer(audio_before, "recovered_packets"),
        "missing_capture_sample_growth": integer(
            audio_after, "missing_capture_samples"
        ) - integer(audio_before, "missing_capture_samples"),
        "receive_callback_growth": integer(audio_after, "receive_callbacks")
        - integer(audio_before, "receive_callbacks"),
        "capture_ring_high_water": integer(after, "capture_ring_high_water"),
        "capture_ring_drop_growth": integer(after, "capture_ring_drops")
        - integer(before, "capture_ring_drops"),
        "stream_failure_growth": integer(after, "stream_failures")
        - integer(before, "stream_failures"),
        "driver": driver_metrics,
        "first_holes": [
            {
                "at_seconds": start / 48_000,
                "duration_ms": (end - start) * 1_000 / 48_000,
            }
            for start, end in holes[:20]
        ],
    }
    integrity_failures = []
    for key in (
        "missing_packet_growth",
        "missing_capture_sample_growth",
        "capture_ring_drop_growth",
        "stream_failure_growth",
    ):
        if result[key] != 0:
            integrity_failures.append(f"{key}={result[key]}")
    if result["accepted_packet_growth"] <= 0:
        integrity_failures.append("no_session_audio_packets")
    if result["maximum_hole_ms"] > args.maximum_hole_ms:
        integrity_failures.append(
            f"maximum_hole_ms={result['maximum_hole_ms']:.3f}"
        )
    if result["total_hole_ms"] > args.maximum_total_hole_ms:
        integrity_failures.append(
            f"total_hole_ms={result['total_hole_ms']:.3f}"
        )
    result["integrity_failures"] = integrity_failures
    result["passed"] = not integrity_failures
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not integrity_failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
