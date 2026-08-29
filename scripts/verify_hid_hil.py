#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import selectors
import subprocess
import sys
import time
from typing import Any

from harness.verifier.macos_hid_event_stream import verify_events
from scripts.verify_runtime_hil import send_command


class BlockedError(RuntimeError):
    pass


def assert_device_hid_delta(
    before: dict[str, Any],
    after: dict[str, Any],
) -> None:
    if before.get("hid_connected") is not True or after.get("hid_connected") is not True:
        raise AssertionError("Cardputer BLE HID is not connected")
    before_failures = int(before.get("hid_report_failures", -1))
    after_failures = int(after.get("hid_report_failures", -1))
    if before_failures < 0 or after_failures != before_failures:
        raise AssertionError(
            "firmware HID send failure counter changed "
            f"(before={before_failures}, after={after_failures})"
        )
    before_total = int(before.get("hid_report_total", -1))
    after_total = int(after.get("hid_report_total", -1))
    if after_total - before_total != 2:
        raise AssertionError(
            "expected exactly one HID down/up pair "
            f"(before={before_total}, after={after_total})"
        )
    if after.get("input_all_keys_up") is not True:
        raise AssertionError("firmware did not finish with all keys up")


def read_consumer_until_ready(
    process: subprocess.Popen[str],
    *,
    deadline: float,
) -> list[str]:
    if process.stdout is None:
        raise AssertionError("consumer stdout is unavailable")
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    lines: list[str] = []
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                remainder = process.stdout.read()
                if remainder:
                    lines.extend(line for line in remainder.splitlines() if line)
                break
            for key, _ in selector.select(timeout=0.1):
                line = key.fileobj.readline().strip()
                if not line:
                    continue
                lines.append(line)
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("result") == "BLOCKED":
                    raise BlockedError(str(event.get("code", "consumer_blocked")))
                if event.get("event") == "consumer_ready":
                    return lines
    finally:
        selector.close()
    raise AssertionError(f"consumer_not_ready output={lines}")


def collect_consumer_result(
    process: subprocess.Popen[str],
    initial_lines: list[str],
    *,
    timeout_seconds: float,
) -> tuple[list[dict[str, Any]], list[str]]:
    try:
        remainder, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        process.terminate()
        remainder, _ = process.communicate(timeout=1)
        raise AssertionError("macOS HID consumer did not terminate")
    lines = initial_lines + [line for line in remainder.splitlines() if line]
    events: list[dict[str, Any]] = []
    for line in lines:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if value.get("event") == "macos_key":
            events.append(value)
    if process.returncode == 2:
        raise BlockedError("macOS HID consumer permission unavailable")
    if process.returncode != 0:
        raise AssertionError(
            f"macOS HID consumer failed exit={process.returncode} output={lines}"
        )
    return events, lines


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Verify Cardputer serial action -> BLE HID -> macOS key events."
    )
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--case", choices=("q", "g0-q"), required=True)
    args = parser.parse_args()

    command = "hid q" if args.case == "q" else "hid g0+q"
    modifier_name = "none" if args.case == "q" else "control+command"
    expected_modifiers = 0 if args.case == "q" else 0x140000
    process: subprocess.Popen[str] | None = None
    try:
        with serial.Serial(
            args.port,
            115200,
            timeout=0.1,
            write_timeout=1,
        ) as transport:
            time.sleep(0.4)
            transport.reset_input_buffer()
            before = send_command(transport, "status")
            process = subprocess.Popen(
                [
                    args.consumer,
                    "--keycode",
                    "12",
                    "--modifiers",
                    modifier_name,
                    "--timeout-ms",
                    "3000",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            lines = read_consumer_until_ready(
                process,
                deadline=time.monotonic() + 2,
            )
            after = send_command(transport, command)
            events, consumer_output = collect_consumer_result(
                process,
                lines,
                timeout_seconds=4,
            )
            assert_device_hid_delta(before, after)
            failures = verify_events(
                events,
                expected_keycode=12,
                expected_modifiers=expected_modifiers,
            )
            if failures:
                raise AssertionError(
                    "macOS event verifier rejected stream "
                    + json.dumps(
                        [failure.__dict__ for failure in failures],
                        ensure_ascii=False,
                    )
                )
    except BlockedError as error:
        if process is not None and process.poll() is None:
            process.terminate()
        print(json.dumps({"result": "BLOCKED", "error": str(error)}))
        return 2
    except (AssertionError, OSError, serial.SerialException) as error:
        if process is not None and process.poll() is None:
            process.terminate()
        print(json.dumps({"result": "FAIL", "error": str(error)}))
        return 1

    print(
        json.dumps(
            {
                "result": "PASS",
                "case": args.case,
                "device": after,
                "macos_events": events,
                "consumer_output": consumer_output,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
