#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time
from typing import Any


DIAGNOSTIC_MARKER = '{"v":1,"event":"diagnostic_state"'


def decode_diagnostic(raw_line: bytes) -> dict[str, Any] | None:
    text = raw_line.decode("utf-8", errors="replace").strip()
    # ESP-IDF logging and harness output can share the USB stream. Prefer the
    # final marker so a complete command response remains decodable even when
    # an interrupted telemetry event precedes it on the same line.
    marker_index = text.rfind(DIAGNOSTIC_MARKER)
    if marker_index < 0:
        return None
    try:
        value = json.loads(text[marker_index:])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def read_diagnostic(transport: Any, *, deadline: float, source: str) -> dict[str, Any]:
    captured: list[str] = []
    while time.monotonic() < deadline:
        raw_line = transport.readline()
        if not raw_line:
            continue
        text = raw_line.decode("utf-8", errors="replace").strip()
        if text:
            captured.append(text)
        event = decode_diagnostic(raw_line)
        if event is not None and event.get("source") == source:
            return event
    raise AssertionError(
        f"diagnostic_timeout source={source} captured_tail={captured[-8:]}"
    )


def wait_for_runtime_ready(transport: Any, *, deadline: float) -> None:
    """Wait until the command loop is alive after USB opens or resets the S3."""
    captured: list[str] = []
    while time.monotonic() < deadline:
        raw_line = transport.readline()
        if not raw_line:
            continue
        text = raw_line.decode("utf-8", errors="replace").strip()
        if text:
            captured.append(text)
        event = decode_diagnostic(raw_line)
        if event is not None and event.get("source") == "telemetry":
            return
        if '"event":"ready"' in text:
            return
    raise AssertionError(f"runtime_ready_timeout captured_tail={captured[-8:]}")


def send_command(transport: Any, command: str) -> dict[str, Any]:
    transport.write((command + "\r\n").encode("utf-8"))
    # pyserial.flush() maps to tcdrain() on macOS. USB Serial/JTAG can leave
    # that ioctl blocked indefinitely after a BLE HID report even though the
    # bytes have already entered the kernel queue. write_timeout bounds the
    # write itself; the firmware response below is the delivery acknowledgement.
    return read_diagnostic(
        transport,
        deadline=time.monotonic() + 1.5,
        source="serial",
    )


def assert_fields(event: dict[str, Any], **expected: Any) -> None:
    mismatches = {
        key: {"expected": value, "actual": event.get(key)}
        for key, value in expected.items()
        if event.get(key) != value
    }
    if mismatches:
        raise AssertionError(f"state_mismatch {mismatches}")


def verify_serial_control(transport: Any) -> dict[str, Any]:
    send_command(transport, "control lost")
    initial = send_command(transport, "status")
    assert_fields(initial, control_authenticated=False, mic_intent="muted")

    authenticated = send_command(transport, "control auth")
    assert_fields(authenticated, control_authenticated=True)
    heartbeat = send_command(transport, "heartbeat")
    assert_fields(heartbeat, control_authenticated=True)
    if heartbeat.get("serial_heartbeat_total", 0) < 1:
        raise AssertionError("serial heartbeat counter did not increment")

    live = send_command(transport, "mic live")
    assert_fields(live, control_authenticated=True, mic_intent="live")

    time.sleep(1.35)
    expired = send_command(transport, "status")
    assert_fields(expired, control_authenticated=False, mic_intent="muted")
    return expired


def verify_ble_heartbeat(transport: Any, observation_seconds: float) -> dict[str, Any]:
    before = send_command(transport, "status")
    before_count = int(before.get("ble_heartbeat_total", 0))
    deadline = time.monotonic() + observation_seconds
    after = before
    while time.monotonic() < deadline:
        time.sleep(min(0.5, max(0.0, deadline - time.monotonic())))
        after = send_command(transport, "status")
        after_count = int(after.get("ble_heartbeat_total", 0))
        if after_count > before_count:
            return after
    raise AssertionError(
        "app heartbeat did not reach firmware "
        f"(before={before_count}, "
        f"after={int(after.get('ble_heartbeat_total', 0))}, "
        f"physical_ble_authenticated={after.get('physical_ble_authenticated')})"
    )


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Exercise and observe the running Cardputer Bridge over USB serial."
    )
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument(
        "--mode",
        choices=("serial-control", "ble-heartbeat"),
        default="serial-control",
    )
    parser.add_argument("--observation-seconds", type=float, default=2.5)
    parser.add_argument(
        "--macos-probe",
        default=str(Path.home() / ".local/share/cardputer-bridge/runtime/macos-state.json"),
    )
    args = parser.parse_args()

    try:
        transport = serial.Serial(
            port=None,
            baudrate=115200,
            timeout=0.1,
            write_timeout=1,
        )
        transport.port = args.port
        transport.dtr = False
        transport.rts = False
        with transport:
            wait_for_runtime_ready(
                transport,
                deadline=time.monotonic() + 8,
            )
            transport.reset_input_buffer()
            if args.mode == "serial-control":
                event = verify_serial_control(transport)
            else:
                event = verify_ble_heartbeat(transport, args.observation_seconds)
    except (AssertionError, OSError, serial.SerialException) as error:
        probe: dict[str, Any] | None = None
        try:
            decoded = json.loads(Path(args.macos_probe).read_text(encoding="utf-8"))
            if isinstance(decoded, dict):
                probe = decoded
        except (OSError, json.JSONDecodeError):
            pass
        print(
            json.dumps(
                {"result": "FAIL", "error": str(error), "macos_probe": probe},
                ensure_ascii=False,
            )
        )
        return 1

    print(json.dumps({"result": "PASS", "event": event}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
