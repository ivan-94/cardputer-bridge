#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from typing import Any, Callable

from verify_audio_hil import click_app_microphone_toggle


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROBE = Path.home() / ".local/share/cardputer-bridge/runtime/macos-state.json"
SERIAL_PYTHON = os.environ.get(
    "CARDPUTER_SERIAL_PYTHON",
    str(Path.home() / ".local/share/cardputer-bridge/launcher-venv/bin/python"),
)
SERIAL_PORT = os.environ.get("CARDPUTER_PORT", "/dev/cu.usbmodem2101")
AUDIO_CONSUMER = os.environ.get(
    "CARDPUTER_AUDIO_PCM_CONSUMER",
    str(
        Path.home()
        / "Applications/Cardputer Audio Verifier.app/Contents/MacOS/audio_pcm_consumer"
    ),
)


def read_probe() -> dict[str, Any]:
    snapshot = json.loads(PROBE.read_text(encoding="utf-8"))
    encoded_device = snapshot.get("device_state", "")
    snapshot["parsed_device_state"] = (
        json.loads(encoded_device) if encoded_device else {}
    )
    return snapshot


def wait_for(
    description: str,
    predicate: Callable[[dict[str, Any]], bool],
    timeout: float = 12.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        try:
            last = read_probe()
            if predicate(last):
                return last
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"timeout_{description} last={last}")


def device_is(snapshot: dict[str, Any], intent: str, gate: str) -> bool:
    device = snapshot.get("parsed_device_state", {})
    return device.get("mic_intent") == intent and device.get("capture_gate") == gate


def main() -> int:
    initial = wait_for(
        "ready",
        lambda value: value.get("phase") == "ready" and bool(value.get("device_state")),
    )
    try:
        if not device_is(initial, "live", "open"):
            click_app_microphone_toggle()
            wait_for("live", lambda value: device_is(value, "live", "open"))

        restarted_at = time.monotonic()
        subprocess.run(
            [str(PROJECT_ROOT / "scripts/restart-macos-app.sh")],
            cwd=PROJECT_ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        recovered = wait_for(
            "restart_muted",
            lambda value: (
                value.get("phase") == "ready"
                and value.get("desired_mic_intent") == "muted"
                and device_is(value, "muted", "closed")
            ),
        )
        muted_at_ms = round((time.monotonic() - restarted_at) * 1_000)
        heartbeat_before = int(recovered.get("heartbeat_write_acknowledged_total", 0))
        stable = wait_for(
            "muted_heartbeat_progress",
            lambda value: (
                value.get("desired_mic_intent") == "muted"
                and device_is(value, "muted", "closed")
                and int(value.get("heartbeat_write_acknowledged_total", 0))
                >= heartbeat_before + 2
            ),
            timeout=5.0,
        )
        serial_oracle = json.loads(subprocess.run(
            [
                SERIAL_PYTHON,
                str(PROJECT_ROOT / "scripts/verify_config_hil.py"),
                "--port",
                SERIAL_PORT,
            ],
            cwd=PROJECT_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout)
        with tempfile.TemporaryDirectory(prefix="cardputer-restart-mute-") as directory:
            evidence_root = Path(directory)
            pcm_metrics_path = evidence_root / "metrics.json"
            subprocess.run(
                [
                    AUDIO_CONSUMER,
                    "--capture-name",
                    "Cardputer Microphone",
                    "--frames",
                    "4800",
                    "--raw",
                    str(evidence_root / "capture.f32le"),
                    "--metrics",
                    str(pcm_metrics_path),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            pcm_metrics = json.loads(pcm_metrics_path.read_text(encoding="utf-8"))
        if pcm_metrics.get("active_peak") != 0 or pcm_metrics.get("tail_peak") != 0:
            raise AssertionError(f"restart_system_pcm_not_silent metrics={pcm_metrics}")

        # Restart once more from the normal muted idle state. Previously the
        # state characteristic could be cached as a telemetry event, leaving
        # a fresh App process with an empty device snapshot and no audio offer.
        # This is the everyday login/relaunch path, independent of the safety
        # transition from live to muted checked above.
        idle_restart_at = time.monotonic()
        subprocess.run(
            [str(PROJECT_ROOT / "scripts/restart-macos-app.sh")],
            cwd=PROJECT_ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        idle_recovered = wait_for(
            "muted_idle_restart_state_and_audio",
            lambda value: (
                value.get("phase") == "ready"
                and value.get("hid_connected") is True
                and device_is(value, "muted", "closed")
                and int(value.get("audio_offer_attempt_total", 0)) > 0
            ),
        )
        idle_restart_ms = round((time.monotonic() - idle_restart_at) * 1_000)
        print(json.dumps({
            "verdict": "PASS",
            "restart_to_muted_ms": muted_at_ms,
            "muted_idle_restart_recovery_ms": idle_restart_ms,
            "desired_mic_intent": stable.get("desired_mic_intent"),
            "device_mic_intent": stable["parsed_device_state"].get("mic_intent"),
            "capture_gate": stable["parsed_device_state"].get("capture_gate"),
            "heartbeat_ack_growth": int(
                stable.get("heartbeat_write_acknowledged_total", 0)
            ) - heartbeat_before,
            "serial_oracle": serial_oracle.get("result"),
            "system_pcm_active_peak": pcm_metrics.get("active_peak"),
            "system_pcm_tail_peak": pcm_metrics.get("tail_peak"),
            "idle_restart_hid_connected": idle_recovered.get("hid_connected"),
            "idle_restart_audio_offer_attempt_total": idle_recovered.get(
                "audio_offer_attempt_total"
            ),
        }, ensure_ascii=False, sort_keys=True))
        return 0
    finally:
        try:
            current = read_probe()
            if current.get("phase") == "ready" and device_is(current, "live", "open"):
                click_app_microphone_toggle()
                wait_for("cleanup_muted", lambda value: device_is(value, "muted", "closed"))
        except Exception as error:
            print(f"WARN restart mute HIL cleanup failed: {error}")


if __name__ == "__main__":
    raise SystemExit(main())
