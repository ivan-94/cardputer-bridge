#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

from verify_runtime_hil import assert_fields, send_command


def wait_for_led_target(
    transport: Any,
    target: str,
    timeout: float = 2.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        last = send_command(transport, "status")
        if last.get("recording_led_target") == target:
            assert_fields(
                last,
                led_driver_enabled=True,
                led_count=1,
            )
            expected_power_hold = target == "red"
            assert_fields(
                last,
                recording_led_brightness=64,
                recording_led_rgb="#FF3C10",
                recording_led_power_hold=expected_power_hold,
            )
            return last
        time.sleep(0.05)
    raise AssertionError(
        f"recording_led_target_timeout expected={target!r} actual={last!r}"
    )


def verify_recording_led(transport: Any, hold_seconds: float) -> dict[str, Any]:
    send_command(transport, "led off")
    wait_for_led_target(transport, "off")

    send_command(transport, "led red")
    red = wait_for_led_target(transport, "red")

    deadline = time.monotonic() + hold_seconds
    last = red
    while time.monotonic() < deadline:
        time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))
        last = send_command(transport, "status")
        assert_fields(
            last,
            recording_led_target="red",
            led_driver_enabled=True,
            led_count=1,
        )
    return last


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Hold the Cardputer recording LED solid red for physical observation."
    )
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument("--hold-seconds", type=float, default=15.0)
    args = parser.parse_args()

    result: dict[str, Any] | None = None
    try:
        with serial.Serial(
            args.port,
            115200,
            timeout=0.1,
            write_timeout=1,
        ) as transport:
            time.sleep(0.4)
            transport.reset_input_buffer()
            try:
                result = verify_recording_led(transport, args.hold_seconds)
            finally:
                send_command(transport, "led off")
                wait_for_led_target(transport, "off")
    except (AssertionError, OSError, serial.SerialException) as error:
        print(
            json.dumps(
                {"result": "FAIL", "error": str(error)},
                ensure_ascii=False,
            )
        )
        return 1

    print(
        json.dumps(
            {
                "result": "PASS",
                "observation": "solid_red_then_off",
                "hold_seconds": args.hold_seconds,
                "event": result,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
