#!/usr/bin/env python3
"""Check UDP plaintext v2/320-sample audio, not acoustic quality or physical G0 debounce.

Opening the USB serial port can reset the Cardputer. This command requires an
explicit --allow-device-reset, never fakes BLE authentication/heartbeats, and
returns the microphone to muted. Runtime probes must come from the running App.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import time


def fresh_probe(path: Path, started_at: float, now: float) -> dict:
    try:
        modified = path.stat().st_mtime
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or modified < started_at or now - modified > 5:
            return {}
        return value
    except (OSError, ValueError):
        return {}


def health_failure(device: dict, baseline: dict, audio: dict, initial_audio: dict) -> str | None:
    for key in ("stream_frames_sent", "stream_failures", "capture_overruns"):
        if key not in device or key not in baseline:
            return f"missing_counter:{key}"
        if device[key] < baseline[key]:
            return f"counter_reset:{key}"
    if device["stream_failures"] > baseline["stream_failures"]:
        return "audio_transport_failed"
    if device["capture_overruns"] > baseline["capture_overruns"]:
        return "captured_audio_dropped"
    if device.get("mic_intent") != "live" or device.get("capture_gate") != "open":
        return "microphone_paused"
    if not all(device.get(k) is True for k in (
        "physical_ble_authenticated", "control_authenticated", "wifi_connected", "audio_receiver_ready"
    )):
        return "live_link_lost"
    if not audio:
        return "mac_probe_stale_or_missing"
    if audio.get("session_id") != initial_audio.get("session_id"):
        return "audio_session_rotated"
    for key in ("missing_packets", "duplicate_or_late_packets"):
        if key not in audio or key not in initial_audio:
            return f"missing_counter:{key}"
        if audio[key] != initial_audio[key]:
            return f"mac_audio_discontinuity:{key}"
    return None


def progress_failure(sent: int, received: int, seconds: float) -> str | None:
    # The wire rate is 50 fps. A 47 fps capture can have continuous packet
    # numbers while losing samples before framing; allow only startup/probe lag.
    if min(sent, received) < seconds * 49:
        return "insufficient_real_audio_progress"
    return None


def run(args: argparse.Namespace) -> dict:
    import serial  # Keep offline verdict tests independent of USB dependencies.

    serial_port = serial.Serial(port=None, baudrate=115200, timeout=0.05, write_timeout=1)
    serial_port.port = args.port
    serial_port.dtr = False
    serial_port.rts = False
    started_at = time.time()
    serial_port.open()
    deadline = time.monotonic() + args.ready_timeout + args.seconds
    boot_ok = False
    triggered = None
    seen_live = False
    ready_since = None
    ready_session = None
    baseline = {}
    initial_audio = {}
    next_poll = 0.0
    verdict = {"result": "FAIL", "reason": "readiness_timeout"}
    try:
        log_fd = os.open(args.log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(log_fd, "w", encoding="utf-8") as journal:
            while time.monotonic() < deadline:
                now = time.monotonic()
                if now >= next_poll:
                    serial_port.write(b"status\r\n")
                    next_poll = now + 0.5
                line = serial_port.readline().decode(errors="replace").strip()
                if not line:
                    continue
                journal.write(json.dumps({"t": time.time(), "line": line}) + "\n")
                journal.flush()
                marker = line.find('{"v":1,')
                if marker < 0:
                    continue
                try:
                    event = json.loads(line[marker:])
                except ValueError:
                    continue
                if event.get("event") == "ready":
                    boot_ok = event.get("board") == "CardputerADV" and event.get("keyboard_ready") is True
                    if not boot_ok or triggered is not None:
                        verdict["reason"] = "board_keyboard_or_unexpected_reboot"
                        break
                if event.get("event") != "diagnostic_state":
                    continue
                audio = fresh_probe(args.audio_probe, started_at, time.time())
                ble = fresh_probe(args.ble_probe, started_at, time.time())
                for name, state in (("audio", audio), ("ble", ble)):
                    journal.write(json.dumps({"t": time.time(), "probe": name, "state": state}) + "\n")
                if audio and (audio.get("transport") != "udp" or
                              audio.get("audio_format") != "pcm16le-v2" or
                              audio.get("audio_encrypted") is not False):
                    verdict["reason"] = "requires_plaintext_v2_udp_50fps"
                    break
                if triggered is None:
                    session = audio.get("session_id")
                    ready = (
                        boot_ok and session and audio.get("accepted_packets", 0) >= 3
                        and all(event.get(k) is True for k in (
                            "physical_ble_authenticated", "control_authenticated", "wifi_connected", "audio_receiver_ready"
                        ))
                        and ble.get("command_write_queue_depth") == 0
                        and ble.get("command_write_in_flight") is False
                        and ble.get("desired_mic_intent") == "muted"
                    )
                    if not ready or session != ready_session:
                        ready_since = None
                        ready_session = session
                    if ready and ready_since is None:
                        ready_since = now
                    if ready and now - ready_since >= 4:
                        baseline = event
                        initial_audio = audio
                        triggered = now
                        serial_port.write(b"mic live\r\n")
                    continue
                seen_live |= event.get("mic_intent") == "live" and event.get("capture_gate") == "open"
                if not seen_live:
                    if now - triggered >= 2:
                        verdict["reason"] = "capture_did_not_open"
                        break
                    continue
                reason = health_failure(event, baseline, audio, initial_audio)
                if reason:
                    verdict["reason"] = reason
                    break
                if now - triggered >= args.seconds:
                    # The tested wire format is 50 frames/s (320 samples at 16 kHz).
                    sent = event["stream_frames_sent"] - baseline["stream_frames_sent"]
                    received = audio.get("accepted_packets", 0) - initial_audio["accepted_packets"]
                    reason = progress_failure(sent, received, args.seconds)
                    if reason:
                        verdict.update(reason=reason, sent=sent, received=received)
                    else:
                        verdict = {"result": "PASS", "seconds": args.seconds, "sent": sent, "received": received}
                    break
    finally:
        try:
            if triggered is not None:
                serial_port.write(b"mic muted\r\n")
                serial_port.flush()
        finally:
            serial_port.close()
    return verdict


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-device-reset", action="store_true", required=True)
    parser.add_argument("--port", required=True)
    parser.add_argument("--audio-probe", type=Path, required=True)
    parser.add_argument("--ble-probe", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True, help="New private log file; may contain network identifiers")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--ready-timeout", type=float, default=35)
    args = parser.parse_args()
    if args.seconds < 5 or args.ready_timeout < 5:
        parser.error("durations must be at least five seconds")
    result = run(args)
    print(json.dumps(result))
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
