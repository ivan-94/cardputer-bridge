#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time

from verify_runtime_hil import send_command


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Read and verify the persisted Cardputer shortcut configuration."
    )
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument("--expected-version", type=int)
    parser.add_argument("--expected-schema", type=int, default=3)
    args = parser.parse_args()

    try:
        with serial.Serial(
            args.port,
            115200,
            timeout=0.1,
            write_timeout=1,
        ) as transport:
            time.sleep(0.4)
            transport.reset_input_buffer()
            event = send_command(transport, "status")
        version = int(event.get("config_version", -1))
        schema = int(event.get("config_schema", -1))
        if schema != args.expected_schema:
            raise AssertionError(
                f"config_schema_mismatch expected={args.expected_schema} actual={schema}"
            )
        if args.expected_version is not None and version != args.expected_version:
            raise AssertionError(
                f"config_version_mismatch expected={args.expected_version} actual={version}"
            )
        if event.get("mic_intent") != "muted" or event.get("capture_gate") != "closed":
            raise AssertionError("config_check_must_leave_device_fail_closed")
        if event.get("input_all_keys_up") is not True:
            raise AssertionError("config_check_found_stuck_hid_state")
        if int(event.get("control_command_drops", -1)) != 0:
            raise AssertionError("control_command_drops_present")
        battery_level = int(event.get("battery_level", -1))
        if not 0 <= battery_level <= 100:
            raise AssertionError(f"battery_level_invalid value={battery_level}")
    except (AssertionError, OSError, ValueError, serial.SerialException) as error:
        print(json.dumps({"result": "FAIL", "error": str(error)}))
        return 1

    print(json.dumps({
        "result": "PASS",
        "config_version": version,
        "config_schema": schema,
        "mic_intent": event["mic_intent"],
        "capture_gate": event["capture_gate"],
        "control_command_drops": event["control_command_drops"],
        "battery_level": battery_level,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
