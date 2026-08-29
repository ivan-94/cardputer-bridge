#!/usr/bin/env python3
from __future__ import annotations

import json
import math
from pathlib import Path
import struct
import sys


def read_float32(path: Path) -> tuple[list[float], list[str]]:
    contents = path.read_bytes()
    errors: list[str] = []
    if not contents:
        errors.append("capture_empty")
    if len(contents) % 4 != 0:
        errors.append("capture_not_float32_aligned")
        samples: list[float] = []
    else:
        samples = [sample[0] for sample in struct.iter_unpack("<f", contents)]
    return samples, errors


def verify_silence(path: Path, tolerance: float = 0.000001) -> dict[str, object]:
    samples, errors = read_float32(path)
    finite_samples = [sample for sample in samples if math.isfinite(sample)]
    if len(finite_samples) != len(samples):
        errors.append("non_finite_sample")
    peak = max((abs(sample) for sample in finite_samples), default=0.0)
    if peak > tolerance:
        errors.append("non_silent_sample")
    return {
        "valid": not errors,
        "errors": errors,
        "frames": len(samples),
        "peak": peak,
        "capture": str(path),
    }


def verify_counting_pulse_and_silence(path: Path) -> dict[str, object]:
    samples, errors = read_float32(path)
    if any(not math.isfinite(sample) for sample in samples):
        errors.append("non_finite_sample")
    pulse_indices = [
        index
        for index, sample in enumerate(samples)
        if math.isfinite(sample) and abs(abs(sample) - 0.5) <= 0.000001
    ]
    pulse_frames = 0
    if not pulse_indices:
        errors.append("counting_pulse_shape_invalid")
    else:
        begin = pulse_indices[0]
        end = pulse_indices[-1] + 1
        pulse = samples[begin:end]
        pulse_frames = len(pulse)
        shape_valid = pulse_frames >= 960 and all(
            math.isfinite(sample) and abs(abs(sample) - 0.5) <= 0.000001
            for sample in pulse
        )
        run_lengths: list[int] = []
        if shape_valid:
            previous_positive = pulse[0] > 0
            run_length = 0
            for sample in pulse:
                positive = sample > 0
                if positive != previous_positive:
                    run_lengths.append(run_length)
                    run_length = 0
                    previous_positive = positive
                run_length += 1
            run_lengths.append(run_length)
            shape_valid = (
                1 <= run_lengths[0] <= 240
                and 1 <= run_lengths[-1] <= 240
                and all(length == 240 for length in run_lengths[1:-1])
            )
        if not shape_valid:
            errors.append("counting_pulse_shape_invalid")
        tail = samples[end:]
        if len(tail) < 240 or any(
            not math.isfinite(sample) or abs(sample) > 0.000001 for sample in tail
        ):
            errors.append("digital_silence_tail_missing")
    return {
        "valid": not errors,
        "errors": errors,
        "frames": len(samples),
        "pulse_frames": pulse_frames,
        "capture": str(path),
    }


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 2 or arguments[0] not in {
        "--require-silence",
        "--require-counting-pulse-and-silence",
    }:
        print(
            "usage: python3 -m harness.verifier.pcm_raw "
            "--require-silence|--require-counting-pulse-and-silence <capture.f32le>",
            file=sys.stderr,
        )
        return 2
    result = (
        verify_silence(Path(arguments[1]))
        if arguments[0] == "--require-silence"
        else verify_counting_pulse_and_silence(Path(arguments[1]))
    )
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
