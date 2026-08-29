#!/usr/bin/env python3
"""Fail if the live Cardputer microphone falls back to second-scale latency."""

from __future__ import annotations

import argparse
import array
import json
import math
from pathlib import Path
import serial
import struct
import subprocess
import tempfile
import time
import wave

from verify_audio_hil import click_app_microphone_toggle, wait_for_mic_intent
from verify_runtime_hil import send_command


def write_tone(path: Path, frequency: int) -> None:
    sample_rate = 48_000
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"".join(
            struct.pack(
                "<h",
                round(0.9 * 32_767 * math.sin(2 * math.pi * frequency * index / sample_rate)),
            )
            for index in range(sample_rate // 2)
        ))


def goertzel_power(samples: array.array[float], frequency: int, sample_rate: int) -> float:
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


def output_is_muted() -> bool:
    value = subprocess.check_output(
        ["osascript", "-e", "output muted of (get volume settings) as string"],
        text=True,
    )
    return value.strip().lower() == "true"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument(
        "--consumer",
        default=str(
            Path.home()
            / "Applications/Cardputer Audio Verifier.app/Contents/MacOS/audio_pcm_consumer"
        ),
    )
    parser.add_argument("--capture-name", default="Cardputer Microphone")
    parser.add_argument(
        "--macos-probe",
        default=str(Path.home() / ".local/share/cardputer-bridge/runtime/macos-state.json"),
    )
    parser.add_argument("--frequency", type=int, default=1_379)
    parser.add_argument("--maximum-upper-bound-ms", type=float, default=500)
    args = parser.parse_args()

    probe = Path(args.macos_probe)
    was_muted = output_is_muted()
    consumer: subprocess.Popen[str] | None = None
    microphone_live = False
    tone_command_started = 0.0

    with tempfile.TemporaryDirectory(prefix="cardputer-latency-") as directory:
        root = Path(directory)
        tone = root / "tone.wav"
        capture = root / "capture.f32le"
        metrics = root / "metrics.json"
        write_tone(tone, args.frequency)
        try:
            subprocess.run(
                ["osascript", "-e", "set volume without output muted"],
                check=True,
            )
            with serial.Serial(args.port, 115_200, timeout=0.1, write_timeout=1) as transport:
                time.sleep(0.4)
                transport.reset_input_buffer()
                initial = send_command(transport, "status")
                if initial.get("mic_intent") != "muted":
                    click_app_microphone_toggle()
                    wait_for_mic_intent(probe, "muted")
                click_app_microphone_toggle()
                wait_for_mic_intent(probe, "live")
                microphone_live = True

                # Reproduce the original bug: let the producer fill its safety
                # buffer before a Core Audio recorder starts consuming.
                time.sleep(3.0)
                consumer = subprocess.Popen(
                    [
                        args.consumer,
                        "--capture-name", args.capture_name,
                        "--frames", "288000",
                        "--raw", str(capture),
                        "--metrics", str(metrics),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                capture_process_started = time.monotonic()
                time.sleep(2.0)
                tone_command_started = time.monotonic() - capture_process_started
                subprocess.run(
                    ["afplay", "-v", "1.0", str(tone)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                stdout, stderr = consumer.communicate(timeout=10)
                if consumer.returncode != 0:
                    raise RuntimeError(
                        f"audio_consumer_failed stdout={stdout.strip()} stderr={stderr.strip()}"
                    )
                consumer = None
                click_app_microphone_toggle()
                wait_for_mic_intent(probe, "muted")
                microphone_live = False
                transport.reset_input_buffer()
                final = send_command(transport, "status")
        finally:
            if consumer is not None and consumer.poll() is None:
                consumer.terminate()
                consumer.wait(timeout=2)
            if microphone_live:
                try:
                    click_app_microphone_toggle()
                    wait_for_mic_intent(probe, "muted")
                except Exception:
                    pass
            if was_muted:
                subprocess.run(
                    ["osascript", "-e", "set volume with output muted"],
                    check=False,
                )

        values = array.array("f")
        values.frombytes(capture.read_bytes())
        sample_rate = 48_000
        window = sample_rate // 100
        powers = [
            goertzel_power(values[offset:offset + window], args.frequency, sample_rate)
            for offset in range(0, len(values) - window + 1, window)
        ]
        pre_tone_window_count = max(
            1,
            min(len(powers), math.floor(tone_command_started * 100)),
        )
        pre_tone_powers = powers[:pre_tone_window_count]
        noise = sorted(pre_tone_powers)[len(pre_tone_powers) // 2]
        noise_ceiling = max(pre_tone_powers)
        peak = max(powers)
        threshold = max(noise * 100, noise_ceiling * 4, peak * 0.2, 1e-8)
        first_eligible_window = math.ceil(tone_command_started * 100)
        consecutive_windows = 3
        onset_window = next((
            index
            for index in range(
                first_eligible_window,
                max(first_eligible_window, len(powers) - consecutive_windows + 1),
            )
            if all(
                powers[index + offset] >= threshold
                for offset in range(consecutive_windows)
            )
        ), None)
        onset_ms = None if onset_window is None else onset_window * 10.0
        upper_bound_ms = (
            None
            if onset_ms is None
            else onset_ms - tone_command_started * 1_000
        )
        passed = (
            upper_bound_ms is not None
            and 0 <= upper_bound_ms <= args.maximum_upper_bound_ms
            and final.get("mic_intent") == "muted"
            and final.get("capture_gate") == "closed"
        )
        print(json.dumps({
            "result": "PASS" if passed else "FAIL",
            "metric": "acoustic_latency_upper_bound",
            "upper_bound_ms": None if upper_bound_ms is None else round(upper_bound_ms, 1),
            "maximum_upper_bound_ms": args.maximum_upper_bound_ms,
            "tone_command_started_ms": round(tone_command_started * 1_000, 1),
            "captured_onset_ms": onset_ms,
            "frequency_hz": args.frequency,
            "pre_tone_noise_power": noise,
            "pre_tone_noise_ceiling_power": noise_ceiling,
            "tone_peak_power": peak,
            "detection_threshold_power": threshold,
            "restored_output_muted": was_muted,
            "final_mic_intent": final.get("mic_intent"),
            "capture_metrics": json.loads(metrics.read_text(encoding="utf-8")),
        }, ensure_ascii=False))
        return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
