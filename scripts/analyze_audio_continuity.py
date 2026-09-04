#!/usr/bin/env python3
"""Detect exact digital-silence holes in final float32 microphone PCM."""

from __future__ import annotations

import argparse
import json
from array import array
from pathlib import Path


def silence_runs(samples: array, *, threshold: float) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    start: int | None = None
    for index, sample in enumerate(samples):
        silent = abs(sample) <= threshold
        if silent and start is None:
            start = index
        elif not silent and start is not None:
            runs.append((start, index))
            start = None
    if start is not None:
        runs.append((start, len(samples)))
    return runs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--sample-rate", type=int, default=48_000)
    parser.add_argument("--threshold", type=float, default=1e-8)
    parser.add_argument("--minimum-hole-ms", type=float, default=1.0)
    parser.add_argument("--maximum-holes", type=int, default=0)
    parser.add_argument("--maximum-hole-ms", type=float, default=0.0)
    args = parser.parse_args()

    samples = array("f")
    samples.frombytes(args.capture.read_bytes())
    minimum_samples = round(args.sample_rate * args.minimum_hole_ms / 1000)
    holes = [
        (start, end)
        for start, end in silence_runs(samples, threshold=args.threshold)
        if end - start >= minimum_samples
    ]
    durations_ms = [
        (end - start) * 1000 / args.sample_rate for start, end in holes
    ]
    result = {
        "capture": str(args.capture),
        "duration_seconds": len(samples) / args.sample_rate,
        "peak": max(map(abs, samples), default=0.0),
        "hole_count": len(holes),
        "maximum_hole_ms": max(durations_ms, default=0.0),
        "total_hole_ms": sum(durations_ms),
        "first_holes": [
            {
                "at_seconds": start / args.sample_rate,
                "duration_ms": (end - start) * 1000 / args.sample_rate,
            }
            for start, end in holes[:20]
        ],
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))

    if result["peak"] <= args.threshold:
        return 2
    if len(holes) > args.maximum_holes:
        return 1
    if result["maximum_hole_ms"] > args.maximum_hole_ms:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
