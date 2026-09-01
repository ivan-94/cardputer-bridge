#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
from typing import Any

from verify_runtime_hil import assert_fields, send_command


def read_probe(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AssertionError("audio_probe_not_an_object")
    return value


def click_app_microphone_toggle() -> None:
    script = '''
tell application "System Events"
  tell process "Cardputer Bridge"
    set frontmost to true
    set candidates to entire contents of window 1
    repeat with candidate in candidates
      try
        set element to contents of candidate
        if value of attribute "AXIdentifier" of element is "microphone-toggle" then
          perform action "AXPress" of element
          return "pressed"
        end if
      end try
    end repeat
    repeat with candidate in candidates
      try
        set element to contents of candidate
        if value of attribute "AXIdentifier" of element is "navigation-overview" then
          perform action "AXPress" of element
          exit repeat
        end if
      end try
    end repeat
    delay 0.1
    set candidates to entire contents of window 1
    repeat with candidate in candidates
      try
        set element to contents of candidate
        if value of attribute "AXIdentifier" of element is "microphone-toggle" then
          perform action "AXPress" of element
          return "pressed"
        end if
      end try
    end repeat
    error "microphone-toggle accessibility element not found"
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
        raise last_error


def device_state_from_probe(path: Path) -> dict[str, Any]:
    encoded = read_probe(path).get("device_state", "")
    value = json.loads(encoded) if encoded else {}
    if not isinstance(value, dict):
        raise AssertionError("macos_device_state_not_an_object")
    return value


def wait_for_mic_intent(path: Path, intent: str, timeout: float = 4.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = device_state_from_probe(path)
        if state.get("mic_intent") == intent:
            expected_gate = "open" if intent == "live" else "closed"
            if state.get("capture_gate") != expected_gate:
                raise AssertionError(
                    f"capture_gate_mismatch value={state.get('capture_gate')}"
                )
            return
        time.sleep(0.1)
    raise AssertionError(f"mic_intent_timeout expected={intent}")


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


def main() -> int:
    import serial

    parser = argparse.ArgumentParser(
        description="Prove live Cardputer microphone capture reaches the Mac App."
    )
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
    parser.add_argument(
        "--control-source",
        choices=("app", "serial"),
        default="app",
        help="Use the visible Mac App control or the authenticated serial harness.",
    )
    args = parser.parse_args()
    probe_path = Path(args.audio_probe)
    macos_probe_path = Path(args.macos_probe)

    try:
        wait_for_audio_session_ready(macos_probe_path)
        before_probe = read_probe(probe_path)
        live_started = False
        with serial.Serial(
            args.port,
            115200,
            timeout=0.1,
            write_timeout=1,
        ) as transport:
            time.sleep(0.4)
            transport.reset_input_buffer()
            try:
                initial = send_command(transport, "status")
                assert_fields(
                    initial,
                    mic_intent="muted",
                    capture_gate="closed",
                    recording_led_target="off",
                    control_authenticated=True,
                    wifi_connected=True,
                    audio_receiver_ready=True,
                )
                if args.control_source == "serial":
                    send_command(transport, "control auth")
                    send_command(transport, "mic live")
                else:
                    click_app_microphone_toggle()
                live_started = True
                wait_for_mic_intent(macos_probe_path, "live")

                deadline = time.monotonic() + args.capture_seconds
                next_serial_heartbeat = time.monotonic()
                while time.monotonic() < deadline:
                    time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))
                    assert_fields(
                        device_state_from_probe(macos_probe_path),
                        mic_intent="live",
                        capture_gate="open",
                    )
                    if (
                        args.control_source == "serial"
                        and time.monotonic() >= next_serial_heartbeat
                    ):
                        heartbeat = send_command(transport, "heartbeat")
                        assert_fields(
                            heartbeat,
                            mic_intent="live",
                            capture_gate="open",
                            recording_led_target="red",
                        )
                        next_serial_heartbeat = time.monotonic() + 0.5
                live_last = send_command(transport, "status")
                assert_fields(
                    live_last,
                    mic_intent="live",
                    capture_gate="open",
                    recording_led_target="red",
                    led_driver_enabled=True,
                    led_count=1,
                )
            finally:
                if live_started:
                    if args.control_source == "serial":
                        send_command(transport, "mic muted")
                    else:
                        click_app_microphone_toggle()
                    wait_for_mic_intent(macos_probe_path, "muted")
            time.sleep(1.0)
            drained = send_command(transport, "status")
            time.sleep(1.5)
            stopped = send_command(transport, "status")
            assert_fields(
                stopped,
                mic_intent="muted",
                capture_gate="closed",
                recording_led_target="off",
            )

        after_probe = read_probe(probe_path)
        sent_growth = int(live_last.get("stream_frames_sent", 0)) - int(
            initial.get("stream_frames_sent", 0)
        )
        accepted_growth = int(after_probe.get("accepted_packets", 0)) - int(
            before_probe.get("accepted_packets", 0)
        )
        stream_failure_growth = int(stopped.get("stream_failures", 0)) - int(
            initial.get("stream_failures", 0)
        )
        capture_overrun_growth = int(stopped.get("capture_overruns", 0)) - int(
            initial.get("capture_overruns", 0)
        )
        # A 160-sample frame at 16 kHz is 10 ms: healthy capture must remain
        # near 100 frames/s. Allow 10% scheduling/network tolerance.
        minimum_stream_packets = max(10, int(args.capture_seconds * 90))
        if sent_growth < minimum_stream_packets:
            raise AssertionError(f"audio_send_growth_too_small value={sent_growth}")
        if accepted_growth < minimum_stream_packets:
            raise AssertionError(
                f"authenticated_audio_growth_too_small value={accepted_growth}"
            )
        missing_growth = int(after_probe.get("missing_packets", 0)) - int(
            before_probe.get("missing_packets", 0)
        )
        if missing_growth != 0:
            raise AssertionError(
                f"audio_stream_sequence_gap value={missing_growth}"
            )
        duplicate_growth = int(
            after_probe.get("duplicate_or_late_packets", 0)
        ) - int(before_probe.get("duplicate_or_late_packets", 0))
        if duplicate_growth != 0:
            raise AssertionError(
                f"audio_stream_duplicate_or_late value={duplicate_growth}"
            )
        if abs(sent_growth - accepted_growth) > 2:
            raise AssertionError(
                "audio_stream_sender_receiver_mismatch "
                f"sent={sent_growth} accepted={accepted_growth}"
            )
        if int(stopped.get("stream_frames_sent", -1)) != int(
            drained.get("stream_frames_sent", -2)
        ):
            raise AssertionError("audio_continued_after_mute")
        if stream_failure_growth != 0:
            raise AssertionError(
                f"stream_failures_grew value={stream_failure_growth}"
            )
        if capture_overrun_growth != 0:
            raise AssertionError(
                f"capture_overruns_grew value={capture_overrun_growth}"
            )
        if float(after_probe.get("signal_level", 0)) <= 0:
            raise AssertionError("captured_pcm_has_no_signal")
    except (
        AssertionError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        serial.SerialException,
        subprocess.CalledProcessError,
    ) as error:
        print(json.dumps({"result": "FAIL", "error": str(error)}, ensure_ascii=False))
        return 1

    print(
        json.dumps(
            {
                "result": "PASS",
                "sent_growth": sent_growth,
                "accepted_growth": accepted_growth,
                "missing_growth": missing_growth,
                "duplicate_or_late_growth": duplicate_growth,
                "muted_stream_frames_sent": stopped["stream_frames_sent"],
                "signal_level": after_probe["signal_level"],
                "stream_failure_growth": stream_failure_growth,
                "capture_overrun_growth": capture_overrun_growth,
                "stream_failures_total": stopped["stream_failures"],
                "capture_overruns_total": stopped["capture_overruns"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
