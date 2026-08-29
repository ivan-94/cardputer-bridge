#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Callable, Protocol

class SerialReader(Protocol):
    def readline(self) -> bytes: ...


class ResettableSerial(Protocol):
    dtr: bool
    rts: bool


def reset_usb_serial_jtag(
    transport: ResettableSerial,
    *,
    settle: Callable[[float], None] = time.sleep,
) -> None:
    """Hard-reset the app through the ESP32-S3 USB-Serial/JTAG port.

    DTR selects the ROM download path, so an app boot verifier first releases
    it. The longer RTS pulse matches esptool's USB hard-reset strategy.
    """
    transport.dtr = False
    transport.rts = True
    settle(0.2)
    transport.rts = False
    settle(0.2)


def decode_event(raw_line: bytes) -> dict[str, object] | None:
    text = raw_line.decode("utf-8", errors="replace").strip()
    if not text.startswith("{"):
        return None
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def wait_for_boot_event(
    reader: SerialReader,
    *,
    deadline: float,
) -> tuple[dict[str, object] | None, list[str]]:
    captured: list[str] = []
    while time.monotonic() < deadline:
        raw_line = reader.readline()
        if not raw_line:
            continue
        text = raw_line.decode("utf-8", errors="replace").strip()
        if text:
            captured.append(text)
        event = decode_event(raw_line)
        if event is not None and event.get("event") in {"ready", "error"}:
            return event, captured
    return None, captured


def find_forbidden_boot_warnings(captured: list[str]) -> list[str]:
    return [line for line in captured if "Partial data write into ADV" in line]


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Reset a connected Cardputer and verify its structured boot event."
    )
    parser.add_argument("--port", required=True)
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    try:
        with serial.Serial(
            port=args.port,
            baudrate=115200,
            timeout=0.1,
            write_timeout=1,
        ) as transport:
            reset_usb_serial_jtag(transport)
            event, captured = wait_for_boot_event(
                transport,
                deadline=time.monotonic() + args.timeout,
            )
    except (OSError, serial.SerialException) as error:
        print(
            json.dumps(
                {"result": "FAIL", "error": "serial_unavailable", "detail": str(error)},
                ensure_ascii=False,
            )
        )
        return 2

    if event is None:
        print(
            json.dumps(
                {
                    "result": "FAIL",
                    "error": "boot_event_timeout",
                    "captured_tail": captured[-12:],
                },
                ensure_ascii=False,
            )
        )
        return 1
    if event.get("event") == "error":
        print(
            json.dumps(
                {
                    "result": "FAIL",
                    "error": "firmware_boot_error",
                    "event": event,
                    "captured_tail": captured[-12:],
                },
                ensure_ascii=False,
            )
        )
        return 1

    forbidden_boot_warnings = find_forbidden_boot_warnings(captured)
    if forbidden_boot_warnings:
        print(
            json.dumps(
                {
                    "result": "FAIL",
                    "error": "advertising_payload_truncated",
                    "captured": forbidden_boot_warnings,
                },
                ensure_ascii=False,
            )
        )
        return 1

    expected = {
        "build_id": "cardputer-bridge-phase3",
        "board": "CardputerADV",
        "keyboard_ready": True,
        "ble_hid": "advertising",
        "vendor_gatt": "encrypted_mitm",
        "wifi_audio": "waiting_for_config",
    }
    mismatches = {
        key: {"expected": expected_value, "actual": event.get(key)}
        for key, expected_value in expected.items()
        if event.get(key) != expected_value
    }
    if mismatches:
        print(
            json.dumps(
                {"result": "FAIL", "error": "ready_contract_mismatch", "mismatches": mismatches},
                ensure_ascii=False,
            )
        )
        return 1

    print(json.dumps({"result": "PASS", "event": event}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
