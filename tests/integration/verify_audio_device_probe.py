#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

PROBE_TIMEOUT_SECONDS = 15


def run_probe(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            check=False,
            timeout=PROBE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        command = " ".join(arguments)
        print(
            f"Core Audio probe timed out after {PROBE_TIMEOUT_SECONDS}s: {command}",
            file=sys.stderr,
        )
        raise SystemExit(1) from error


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_audio_device_probe.py <audio-device-probe>", file=sys.stderr)
        return 2
    probe = Path(sys.argv[1])

    listed = run_probe([str(probe), "--list"])
    if listed.returncode != 0:
        print(listed.stderr, file=sys.stderr)
        return 1
    device_count = 0
    for line in listed.stdout.splitlines():
        event = json.loads(line)
        if event.get("event") != "audio_device":
            print(f"unexpected event: {event}", file=sys.stderr)
            return 1
        device_count += 1
    if device_count == 0:
        print("Core Audio enumeration returned no devices", file=sys.stderr)
        return 1

    missing = run_probe(
        [str(probe), "--require-input", "__CARDPUTER_BRIDGE_MISSING_FIXTURE__"]
    )
    if missing.returncode != 1:
        print(f"missing device expected exit 1, got {missing.returncode}", file=sys.stderr)
        return 1
    result = json.loads(missing.stdout)
    if result != {
        "event": "required_audio_input",
        "found": False,
        "name": "__CARDPUTER_BRIDGE_MISSING_FIXTURE__",
    }:
        print(f"unexpected missing-device result: {result}", file=sys.stderr)
        return 1

    missing_running = run_probe(
        [
            str(probe),
            "--require-running-input",
            "__CARDPUTER_BRIDGE_MISSING_FIXTURE__",
        ]
    )
    if missing_running.returncode != 1:
        print(
            f"missing running device expected exit 1, got {missing_running.returncode}",
            file=sys.stderr,
        )
        return 1
    running_result = json.loads(missing_running.stdout)
    if running_result != {
        "event": "required_running_audio_input",
        "found": False,
        "running": False,
        "name": "__CARDPUTER_BRIDGE_MISSING_FIXTURE__",
    }:
        print(f"unexpected missing-running result: {running_result}", file=sys.stderr)
        return 1

    print("PASS audio_device_probe_lists_rejects_missing_and_reports_running_state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
