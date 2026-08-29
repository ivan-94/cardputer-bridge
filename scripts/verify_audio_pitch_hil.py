#!/usr/bin/env python3
"""Acoustically verify that Cardputer capture preserves pitch end to end."""

from __future__ import annotations

import argparse
import array
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import wave

from verify_audio_hil import (
    click_app_microphone_toggle,
    device_state_from_probe,
    wait_for_mic_intent,
)

def write_tone(path: Path, frequency: int, duration: float) -> None:
    sample_rate = 48_000
    frames = int(sample_rate * duration)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(
            b"".join(
                struct.pack(
                    "<h",
                    round(0.8 * 32_767 * math.sin(2 * math.pi * frequency * i / sample_rate)),
                )
                for i in range(frames)
            )
        )


def goertzel_power(samples: list[float], frequency: int, sample_rate: int) -> float:
    coefficient = 2 * math.cos(2 * math.pi * frequency / sample_rate)
    current = previous = previous_previous = 0.0
    for sample in samples:
        current = sample + coefficient * previous - previous_previous
        previous_previous = previous
        previous = current
    return (
        previous * previous
        + previous_previous * previous_previous
        - coefficient * previous * previous_previous
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--consumer",
        default=str(
            Path.home()
            / "Applications/Cardputer Audio Verifier.app/Contents/MacOS/audio_pcm_consumer"
        ),
    )
    parser.add_argument("--capture-name", default="Cardputer Microphone")
    parser.add_argument("--frequency", type=int, default=1_000)
    parser.add_argument("--tolerance-hz", type=int, default=15)
    parser.add_argument(
        "--macos-probe",
        type=Path,
        default=Path.home() / ".local/share/cardputer-bridge/runtime/macos-state.json",
    )
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="cardputer-pitch-") as directory:
        root = Path(directory)
        tone = root / "reference.wav"
        capture = root / "capture.f32le"
        metrics = root / "metrics.json"
        write_tone(tone, args.frequency, 4.0)
        consumer = subprocess.Popen(
            [
                args.consumer,
                "--capture-name",
                args.capture_name,
                "--frames",
                "288000",
                "--raw",
                str(capture),
                "--metrics",
                str(metrics),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        microphone_live = False
        try:
            time.sleep(0.5)
            if device_state_from_probe(args.macos_probe).get("mic_intent") == "live":
                click_app_microphone_toggle()
                wait_for_mic_intent(args.macos_probe, "muted")
            click_app_microphone_toggle()
            wait_for_mic_intent(args.macos_probe, "live")
            microphone_live = True
            time.sleep(0.8)
            subprocess.run(["afplay", "-v", "1.0", str(tone)], check=True)
            time.sleep(0.4)
            click_app_microphone_toggle()
            wait_for_mic_intent(args.macos_probe, "muted")
            microphone_live = False
            _, stderr = consumer.communicate(timeout=3)
            if consumer.returncode != 0:
                raise RuntimeError(f"audio_consumer_failed: {stderr.strip()}")
        finally:
            try:
                if device_state_from_probe(args.macos_probe).get("mic_intent") == "live":
                    click_app_microphone_toggle()
                    wait_for_mic_intent(args.macos_probe, "muted")
            except Exception:
                if microphone_live:
                    click_app_microphone_toggle()
            if consumer.poll() is None:
                consumer.terminate()
                consumer.wait(timeout=2)

        values = array.array("f")
        values.frombytes(capture.read_bytes())
        sample_rate = 48_000
        analysis = list(values[sample_rate * 2 : sample_rate * 5])
        mean = sum(analysis) / len(analysis)
        analysis = [sample - mean for sample in analysis]
        candidates = range(args.frequency - 500, args.frequency + 501, 5)
        detected = max(
            candidates,
            key=lambda candidate: goertzel_power(analysis, candidate, sample_rate),
        )
        result = {
            "result": "PASS"
            if abs(detected - args.frequency) <= args.tolerance_hz
            else "FAIL",
            "expected_hz": args.frequency,
            "detected_hz": detected,
            "error_hz": abs(detected - args.frequency),
            "capture_metrics": json.loads(metrics.read_text(encoding="utf-8")),
        }
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
