#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

CONSUMER_TIMEOUT_SECONDS = 15


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_audio_pcm_consumer.py <consumer>", file=sys.stderr)
        return 2
    consumer = Path(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="cardputer-bridge-pcm-consumer.") as temporary:
        root = Path(temporary)
        raw = root / "capture.f32le"
        metrics = root / "metrics.json"
        try:
            completed = subprocess.run(
                [
                    str(consumer),
                    "--capture-name",
                    "__CardputerBridgeMissingInput__",
                    "--frames",
                    "128",
                    "--raw",
                    str(raw),
                    "--metrics",
                    str(metrics),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=CONSUMER_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            print(
                "Core Audio PCM consumer timed out while resolving a missing input",
                file=sys.stderr,
            )
            return 1
        if completed.returncode != 2:
            print(
                "missing input must be BLOCKED/exit 2\n"
                + completed.stdout
                + completed.stderr,
                file=sys.stderr,
            )
            return 1
        if raw.exists() or metrics.exists():
            print("blocked capture must not create evidence files", file=sys.stderr)
            return 1
    print("PASS audio_pcm_consumer_blocks_without_named_input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
