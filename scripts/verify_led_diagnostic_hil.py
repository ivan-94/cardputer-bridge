#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

from verify_firmware_boot import reset_usb_serial_jtag


def decode_event(raw_line: bytes) -> dict[str, Any] | None:
    text = raw_line.decode("utf-8", errors="replace").strip()
    marker = text.rfind("{")
    if marker < 0:
        return None
    try:
        value = json.loads(text[marker:])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Verify the isolated Cardputer LED diagnostic red/off cycle."
    )
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument("--timeout", type=float, default=35.0)
    args = parser.parse_args()

    captured: list[dict[str, Any]] = []
    red_started_at: float | None = None
    red_ended_at: float | None = None
    ready = False
    try:
        with serial.Serial(
            args.port,
            115200,
            timeout=0.1,
            write_timeout=1,
        ) as transport:
            reset_usb_serial_jtag(transport)
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                event = decode_event(transport.readline())
                if event is None:
                    continue
                captured.append(event)
                if event.get("event") == "led_diagnostic_ready":
                    ready = event.get("pattern") == "red_20s_off_5s"
                if event.get("event") != "led_diagnostic_transition":
                    continue
                if (
                    event.get("driver_enabled") is not True
                    or event.get("led_count") != 1
                ):
                    raise AssertionError(f"led_driver_state_invalid event={event}")
                if event.get("target") == "red" and red_started_at is None:
                    red_started_at = time.monotonic()
                elif (
                    event.get("target") == "off"
                    and red_started_at is not None
                ):
                    red_ended_at = time.monotonic()
                    break
    except (AssertionError, OSError, serial.SerialException) as error:
        print(
            json.dumps(
                {"result": "FAIL", "error": str(error), "captured": captured},
                ensure_ascii=False,
            )
        )
        return 1

    red_seconds = (
        red_ended_at - red_started_at
        if red_started_at is not None and red_ended_at is not None
        else 0.0
    )
    if not ready or red_seconds < 19.5:
        print(
            json.dumps(
                {
                    "result": "FAIL",
                    "error": "diagnostic_cycle_incomplete",
                    "ready": ready,
                    "red_seconds": red_seconds,
                    "captured": captured,
                },
                ensure_ascii=False,
            )
        )
        return 1

    print(
        json.dumps(
            {
                "result": "PASS",
                "red_seconds": red_seconds,
                "captured": captured,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
