#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any


def read_probe(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AssertionError("audio_probe_not_an_object")
    return value


def click_app_microphone_toggle() -> None:
    script = '''
tell application "System Events"
  tell process "Cardputer Bridge"
    click menu bar item 1 of menu bar 2
    delay 0.2
    set candidate to first menu item of menu 1 of menu bar item 1 of menu bar 2 whose name contains "麦克风"
    click candidate
  end tell
end tell
'''
    deadline = time.monotonic() + 3.0
    last_error: subprocess.CalledProcessError | None = None
    while time.monotonic() < deadline:
        try:
            subprocess.run(
                ["osascript", "-e", script],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            return
        except subprocess.CalledProcessError as error:
            last_error = error
            time.sleep(0.1)
    if last_error is not None:
        helper = Path(__file__).with_name("ax_press.swift")
        environment = dict(os.environ)
        environment.setdefault(
            "CLANG_MODULE_CACHE_PATH",
            "/tmp/cardputer-bridge-swift-module-cache",
        )
        subprocess.run(
            [
                "xcrun",
                "swift",
                str(helper),
                "io.nexu.cardputerbridge.app",
                "microphone-toggle",
            ],
            check=True,
            env=environment,
        )


def device_state_from_probe(path: Path) -> dict[str, Any]:
    encoded = read_probe(path).get("device_state", "")
    value = json.loads(encoded) if encoded else {}
    if not isinstance(value, dict):
        raise AssertionError("macos_device_state_not_an_object")
    return value


def wait_for_mic_intent(path: Path, intent: str, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        state = device_state_from_probe(path)
        last = state
        if state.get("mic_intent") == intent:
            expected_gate = "open" if intent == "live" else "closed"
            if state.get("capture_gate") == expected_gate:
                return
        time.sleep(0.1)
    raise AssertionError(f"mic_intent_timeout expected={intent} last={last}")


def wait_for_audio_session_ready(path: Path, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        try:
            probe = read_probe(path)
            encoded = probe.get("device_state", "")
            device = json.loads(encoded) if encoded else {}
            last = {"probe": probe, "device": device}
            if (
                probe.get("phase") == "ready"
                and device.get("wifi") == "connected"
                and device.get("audio") == "ready"
                and device.get("mic_intent") == "muted"
                and device.get("capture_gate") == "closed"
            ):
                # The ESP32-S3 radio has just recovered from reset and shares
                # 2.4 GHz between BLE and Wi-Fi. Let that association/session
                # settle before measuring the strict 60-second loss window.
                time.sleep(3.0)
                return
        except (OSError, ValueError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"audio_session_not_ready last={last}")


def wait_for_receiver_drain(
    path: Path,
    timeout: float = 4.0,
    quiet_seconds: float = 0.5,
) -> dict[str, Any]:
    """Wait until the session-validated UDP stream has no in-flight frames.

    The device counters arrive through a slower BLE telemetry path, so they
    cannot be used as an immediate UDP drain target. Require the receiver's own
    accepted count to remain unchanged for a bounded quiet interval.
    """
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    last_accepted = -1
    quiet_since = time.monotonic()
    while time.monotonic() < deadline:
        last = read_probe(path)
        accepted = int(last.get("accepted_packets", 0))
        if accepted != last_accepted:
            last_accepted = accepted
            quiet_since = time.monotonic()
        elif time.monotonic() - quiet_since >= quiet_seconds:
            return last
        time.sleep(0.05)
    return last


def wait_for_device_counter_refresh(
    path: Path,
    baseline_heartbeat: int,
    timeout: float = 4.0,
) -> dict[str, Any]:
    """Wait for one fresh BLE heartbeat before comparing device counters."""
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        last = read_probe(path)
        if int(last.get("heartbeat_write_acknowledged_total", 0)) > baseline_heartbeat:
            return last
        time.sleep(0.05)
    raise AssertionError("device_counter_refresh_timeout")


def ensure_microphone_muted(path: Path, timeout: float = 10.0) -> None:
    """Leave both App authority and device state safely muted after any run."""
    deadline = time.monotonic() + timeout
    command_sent = False
    while time.monotonic() < deadline:
        probe = read_probe(path)
        device = device_state_from_probe(path)
        desired = probe.get("desired_mic_intent")
        observed = device.get("mic_intent")
        if desired == "muted" and observed == "muted":
            return
        if not command_sent and desired == "live" and observed == "live":
            click_app_microphone_toggle()
            command_sent = True
        time.sleep(0.1)
    raise AssertionError("microphone_cleanup_timeout")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prove live Cardputer microphone capture reaches the Mac App."
    )
    # Retained for CLI compatibility with the other HIL entry points. Audio
    # verification deliberately never opens USB Serial/JTAG because doing so
    # resets a physical Cardputer ADV and destroys the BLE/Wi-Fi session under
    # test.
    parser.add_argument("--port", default="/dev/cu.usbmodem2101")
    parser.add_argument(
        "--audio-probe",
        default=str(Path.home() / ".local/share/cardputer-bridge/runtime/audio-state.json"),
    )
    parser.add_argument(
        "--macos-probe",
        default=str(Path.home() / ".local/share/cardputer-bridge/runtime/macos-state.json"),
    )
    parser.add_argument("--capture-seconds", type=float, default=60.0)
    args = parser.parse_args()
    probe_path = Path(args.audio_probe)
    macos_probe_path = Path(args.macos_probe)
    evidence: dict[str, Any] = {}

    try:
        wait_for_audio_session_ready(macos_probe_path)
        live_started = False
        mute_started_probe: dict[str, Any] = {}
        try:
            click_app_microphone_toggle()
            live_started = True
            wait_for_mic_intent(macos_probe_path, "live")

            # The user action reaches the device before its BLE status and
            # counters return to the App. Establish both baselines only after
            # one fresh heartbeat, otherwise control-plane latency is counted
            # as extra audio and makes short/long runs non-deterministic.
            live_probe = read_probe(macos_probe_path)
            initial_probe = wait_for_device_counter_refresh(
                macos_probe_path,
                int(live_probe.get("heartbeat_write_acknowledged_total", 0)),
            )
            before_probe = read_probe(probe_path)

            deadline = time.monotonic() + args.capture_seconds
            while time.monotonic() < deadline:
                time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))
                device = device_state_from_probe(macos_probe_path)
                if (
                    device.get("mic_intent") != "live"
                    or device.get("capture_gate") != "open"
                ):
                    raise AssertionError(
                        f"audio_capture_stopped_during_window state={device}"
                    )
            mute_started_probe = read_probe(macos_probe_path)
        finally:
            if live_started:
                ensure_microphone_muted(macos_probe_path)

        stopped_probe = wait_for_device_counter_refresh(
            macos_probe_path,
            int(mute_started_probe.get("heartbeat_write_acknowledged_total", 0)),
        )
        sent_growth = int(stopped_probe.get("stream_frames_sent", 0)) - int(
            initial_probe.get("stream_frames_sent", 0)
        )
        after_probe = wait_for_receiver_drain(probe_path)
        time.sleep(0.5)
        after_mute_probe = read_probe(probe_path)

        accepted_growth = int(after_probe.get("accepted_packets", 0)) - int(
            before_probe.get("accepted_packets", 0)
        )
        stream_failure_growth = int(stopped_probe.get("stream_failures", 0)) - int(
            initial_probe.get("stream_failures", 0)
        )
        capture_overrun_growth = int(stopped_probe.get("capture_overruns", 0)) - int(
            initial_probe.get("capture_overruns", 0)
        )
        microphone_record_failure_growth = int(
            stopped_probe.get("microphone_record_failures", 0)
        ) - int(initial_probe.get("microphone_record_failures", 0))
        capture_ring_drop_growth = int(
            stopped_probe.get("capture_ring_drops", 0)
        ) - int(initial_probe.get("capture_ring_drops", 0))
        wifi_disconnect_growth = int(
            stopped_probe.get("wifi_disconnect_count", 0)
        ) - int(initial_probe.get("wifi_disconnect_count", 0))
        missing_growth = int(after_probe.get("missing_packets", 0)) - int(
            before_probe.get("missing_packets", 0)
        )
        recovered_growth = int(after_probe.get("recovered_packets", 0)) - int(
            before_probe.get("recovered_packets", 0)
        )
        duplicate_growth = int(
            after_probe.get("duplicate_or_late_packets", 0)
        ) - int(before_probe.get("duplicate_or_late_packets", 0))
        microphone_write_growth = int(
            after_probe.get("microphone_writes", 0)
        ) - int(before_probe.get("microphone_writes", 0))
        missing_capture_sample_growth = int(
            after_probe.get("missing_capture_samples", 0)
        ) - int(before_probe.get("missing_capture_samples", 0))
        evidence = {
            "sent_growth": sent_growth,
            "accepted_growth": accepted_growth,
            "missing_growth": missing_growth,
            "recovered_growth": recovered_growth,
            "duplicate_or_late_growth": duplicate_growth,
            "microphone_write_growth": microphone_write_growth,
            "missing_capture_sample_growth": missing_capture_sample_growth,
            "stream_failure_growth": stream_failure_growth,
            "capture_overrun_growth": capture_overrun_growth,
            "microphone_record_failure_growth": microphone_record_failure_growth,
            "capture_ring_drop_growth": capture_ring_drop_growth,
            "wifi_disconnect_growth": wifi_disconnect_growth,
            "last_wifi_disconnect_reason": int(
                stopped_probe.get("last_wifi_disconnect_reason", 0)
            ),
            "stream_failures_total": int(stopped_probe.get("stream_failures", 0)),
            "capture_overruns_total": int(stopped_probe.get("capture_overruns", 0)),
        }
        # A 320-sample frame at 16 kHz is 20 ms: healthy capture must remain
        # near 50 frames/s. Allow 10% scheduling/network tolerance.
        minimum_stream_packets = max(10, int(args.capture_seconds * 45))
        if sent_growth < minimum_stream_packets:
            raise AssertionError(f"audio_send_growth_too_small value={sent_growth}")
        if accepted_growth < minimum_stream_packets:
            raise AssertionError(
                f"session_audio_growth_too_small value={accepted_growth}"
            )
        if missing_growth != 0:
            raise AssertionError(
                f"audio_stream_sequence_gap value={missing_growth}"
            )
        if duplicate_growth != 0:
            raise AssertionError(
                f"audio_stream_duplicate_or_late value={duplicate_growth}"
            )
        if missing_capture_sample_growth != 0:
            raise AssertionError(
                "audio_capture_sample_gap "
                f"value={missing_capture_sample_growth}"
            )
        if stream_failure_growth != 0:
            raise AssertionError(
                f"audio_stream_send_failure value={stream_failure_growth}"
            )
        if capture_overrun_growth != 0:
            raise AssertionError(
                f"audio_capture_overrun value={capture_overrun_growth}"
            )
        if microphone_record_failure_growth != 0:
            raise AssertionError(
                "audio_microphone_record_failure "
                f"value={microphone_record_failure_growth}"
            )
        if capture_ring_drop_growth != 0:
            raise AssertionError(
                f"audio_capture_ring_drop value={capture_ring_drop_growth}"
            )
        if wifi_disconnect_growth != 0:
            raise AssertionError(
                f"audio_wifi_disconnect value={wifi_disconnect_growth}"
            )
        if int(after_mute_probe.get("accepted_packets", -1)) != int(
            after_probe.get("accepted_packets", -2)
        ):
            raise AssertionError("audio_continued_after_mute")
        if float(after_probe.get("signal_level", 0)) <= 0:
            raise AssertionError("captured_pcm_has_no_signal")
        if not bool(after_probe.get("system_microphone_ready", False)):
            raise AssertionError("system_microphone_not_ready")
        if microphone_write_growth <= 0:
            raise AssertionError("system_microphone_received_no_audio")
    except (
        AssertionError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        print(json.dumps(
            {"result": "FAIL", "error": str(error), **evidence},
            ensure_ascii=False,
        ))
        return 1

    print(
        json.dumps(
            {
                "result": "PASS",
                "sent_growth": sent_growth,
                "accepted_growth": accepted_growth,
                "missing_growth": missing_growth,
                "recovered_growth": recovered_growth,
                "duplicate_or_late_growth": duplicate_growth,
                "microphone_write_growth": microphone_write_growth,
                "missing_capture_sample_growth": missing_capture_sample_growth,
                "muted_stream_frames_sent": stopped_probe["stream_frames_sent"],
                "signal_level": after_probe["signal_level"],
                "stream_failure_growth": stream_failure_growth,
                "capture_overrun_growth": capture_overrun_growth,
                "microphone_record_failure_growth": microphone_record_failure_growth,
                "capture_ring_drop_growth": capture_ring_drop_growth,
                "wifi_disconnect_growth": wifi_disconnect_growth,
                "last_wifi_disconnect_reason": stopped_probe[
                    "last_wifi_disconnect_reason"
                ],
                "stream_failures_total": stopped_probe["stream_failures"],
                "capture_overruns_total": stopped_probe["capture_overruns"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
