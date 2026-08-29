#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from typing import Any

from verify_runtime_hil import assert_fields, send_command


def counter_delta(before: dict[str, Any], after: dict[str, Any], field: str) -> int:
    return int(after.get(field, -1)) - int(before.get(field, -1))


def verify_idle_efficiency(transport: Any, duration: float) -> dict[str, Any]:
    muted = send_command(transport, "mic muted")
    assert_fields(muted, mic_intent="muted", capture_gate="closed")
    # Let any offer/reconnect test datagrams drain before taking the baseline.
    time.sleep(1.0)
    baseline = send_command(transport, "status")
    assert_fields(baseline, mic_intent="muted", capture_gate="closed")

    deadline = time.monotonic() + duration
    latest = baseline
    while time.monotonic() < deadline:
        time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))
        latest = send_command(transport, "status")
        assert_fields(latest, mic_intent="muted", capture_gate="closed")

    sent_delta = counter_delta(baseline, latest, "udp_sent")
    overrun_delta = counter_delta(baseline, latest, "capture_overruns")
    idle_wait_delta = counter_delta(baseline, latest, "audio_idle_wait_total")
    telemetry_delta = counter_delta(
        baseline,
        latest,
        "wifi_telemetry_refresh_total",
    )
    maximum_idle_waits = math.ceil(duration * 1000 / 250) + 8
    maximum_telemetry_refreshes = math.ceil(duration * 1000 / 5000) + 2
    if sent_delta != 0:
        raise AssertionError(f"muted_audio_packets_sent delta={sent_delta}")
    if overrun_delta != 0:
        raise AssertionError(f"muted_capture_overruns delta={overrun_delta}")
    if not 1 <= idle_wait_delta <= maximum_idle_waits:
        raise AssertionError(
            f"idle_wait_rate_out_of_bounds delta={idle_wait_delta} "
            f"maximum={maximum_idle_waits}"
        )
    if not 0 <= telemetry_delta <= maximum_telemetry_refreshes:
        raise AssertionError(
            f"wifi_telemetry_rate_out_of_bounds delta={telemetry_delta} "
            f"maximum={maximum_telemetry_refreshes}"
        )
    minimum_free_heap = int(latest.get("minimum_free_heap_bytes", 0))
    largest_free_block = int(latest.get("largest_free_block_bytes", 0))
    if minimum_free_heap < 80 * 1024:
        raise AssertionError(f"minimum_free_heap_too_small bytes={minimum_free_heap}")
    if largest_free_block < 32 * 1024:
        raise AssertionError(f"largest_free_block_too_small bytes={largest_free_block}")
    return {
        "duration_seconds": duration,
        "udp_sent_delta": sent_delta,
        "capture_overrun_delta": overrun_delta,
        "idle_wait_delta": idle_wait_delta,
        "notification_wake_delta": counter_delta(
            baseline,
            latest,
            "audio_notification_wake_total",
        ),
        "wifi_telemetry_refresh_delta": telemetry_delta,
        "minimum_free_heap_bytes": minimum_free_heap,
        "largest_free_block_bytes": largest_free_block,
        "main_stack_high_water_words": int(
            latest.get("main_stack_high_water_words", 0)
        ),
        "audio_stack_high_water_words": int(
            latest.get("audio_stack_high_water_words", 0)
        ),
        "control_queue_depth": int(latest.get("control_queue_depth", -1)),
    }


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Verify muted Cardputer task and Wi-Fi polling efficiency."
    )
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument("--duration", type=float, default=10.0)
    args = parser.parse_args()

    try:
        with serial.Serial(args.port, 115200, timeout=0.1, write_timeout=1) as transport:
            time.sleep(0.4)
            transport.reset_input_buffer()
            evidence = verify_idle_efficiency(transport, args.duration)
    except (AssertionError, OSError, serial.SerialException) as error:
        print(json.dumps({"result": "FAIL", "error": str(error)}, ensure_ascii=False))
        return 1

    print(json.dumps({"result": "PASS", "evidence": evidence}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
