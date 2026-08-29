#!/usr/bin/env python3
"""Prove a Cardputer-originated microphone toggle remains authoritative."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import serial

from verify_audio_hil import device_state_from_probe, wait_for_mic_intent
from verify_runtime_hil import assert_fields, send_command


def wait_for_desired_intent(path: Path, intent: str, timeout: float = 4.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("desired_mic_intent") == intent:
            return
        time.sleep(0.1)
    raise AssertionError(f"desired_mic_intent_timeout expected={intent}")


def wait_for_idle_authority(path: Path, timeout: float = 6.0) -> None:
    initial = json.loads(path.read_text(encoding="utf-8"))
    heartbeat_before = int(initial.get("heartbeat_write_acknowledged_total", 0))
    deadline = time.monotonic() + timeout
    last: dict[str, object] = initial
    while time.monotonic() < deadline:
        last = json.loads(path.read_text(encoding="utf-8"))
        encoded_device = last.get("device_state", "")
        device = json.loads(encoded_device) if encoded_device else {}
        if (
            last.get("phase") == "ready"
            and last.get("desired_mic_intent") == "muted"
            and device.get("mic_intent") == "muted"
            and device.get("capture_gate") == "closed"
            and int(last.get("heartbeat_write_acknowledged_total", 0))
            >= heartbeat_before + 2
        ):
            return
        time.sleep(0.1)
    raise AssertionError(f"idle_authority_not_settled last={last}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument(
        "--macos-probe",
        default=str(Path.home() / ".local/share/cardputer-bridge/runtime/macos-state.json"),
    )
    args = parser.parse_args()
    probe = Path(args.macos_probe)
    device_live = False

    try:
        # The preceding restart HIL may have just re-established the App-owned
        # safe mute baseline. Wait until two acknowledged heartbeats prove that
        # no old command is still in flight before injecting a device-originated
        # intent; otherwise the fixture races the safety baseline itself.
        wait_for_idle_authority(probe)
        with serial.Serial(args.port, 115_200, timeout=0.1, write_timeout=1) as transport:
            time.sleep(0.4)
            transport.reset_input_buffer()
            initial = send_command(transport, "status")
            assert_fields(initial, mic_intent="muted", capture_gate="closed")
            try:
                toggled = send_command(transport, "mic live")
                # The command may already have opened capture even if a later
                # assertion fails; arm fail-safe cleanup before inspecting it.
                device_live = True
                assert_fields(toggled, mic_intent="live", capture_gate="open")
                wait_for_mic_intent(probe, "live")
                wait_for_desired_intent(probe, "live")

                # Cross more than one App heartbeat. A stale App-owned mute
                # command must not undo the device-originated state change.
                time.sleep(2.5)
                stable = send_command(transport, "status")
                assert_fields(stable, mic_intent="live", capture_gate="open")
                wait_for_desired_intent(probe, "live")
            finally:
                if device_live:
                    send_command(transport, "mic muted")
                    wait_for_mic_intent(probe, "muted")
                    wait_for_desired_intent(probe, "muted")
            final = send_command(transport, "status")
            assert_fields(final, mic_intent="muted", capture_gate="closed")
    except (AssertionError, OSError, ValueError, serial.SerialException) as error:
        print(json.dumps({"result": "FAIL", "error": str(error)}, ensure_ascii=False))
        return 1

    print(json.dumps({
        "result": "PASS",
        "device_originated_intent": "preserved_across_heartbeat",
        "final_mic_intent": device_state_from_probe(probe).get("mic_intent"),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
