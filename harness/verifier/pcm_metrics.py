#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any


def verify(metrics: dict[str, Any]) -> dict[str, object]:
    errors: list[str] = []
    if metrics.get("sample_rate") != 48000:
        errors.append("sample_rate_invalid")
    if metrics.get("channels") != 1:
        errors.append("channel_count_invalid")
    if metrics.get("sample_format") != "float32":
        errors.append("sample_format_invalid")
    active_peak = metrics.get("active_peak")
    if not isinstance(active_peak, (int, float)) or active_peak < 0.05:
        errors.append("counting_pulse_missing")
    tail_peak = metrics.get("tail_peak")
    if not isinstance(tail_peak, (int, float)) or tail_peak > 0.000001:
        errors.append("tail_not_digitally_silent")
    return {"valid": not errors, "errors": errors}


def verify_file(path: Path) -> dict[str, object]:
    metrics = json.loads(path.read_text(encoding="utf-8"))
    result = verify(metrics)
    result["metrics"] = str(path)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print("usage: python3 -m harness.verifier.pcm_metrics <metrics.json>", file=sys.stderr)
        return 2
    result = verify_file(Path(arguments[0]))
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
