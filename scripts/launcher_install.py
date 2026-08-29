#!/usr/bin/env python3
"""Install one ESP32 application image through M5Launcher without replacing it."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Protocol


CHUNK_SIZE = 2048
APP_DESCRIPTION_MAGIC = b"\x32\x54\xcd\xab"
SAFE_NAME = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
FREE_RANGE = re.compile(r"<free>\s+offset=0x[0-9A-Fa-f]+\s+size=0x([0-9A-Fa-f]+)")


class LauncherInstallError(RuntimeError):
    pass


class SerialTransport(Protocol):
    timeout: float

    def write(self, data: bytes) -> int: ...
    def flush(self) -> None: ...
    def readline(self) -> bytes: ...
    def reset_input_buffer(self) -> None: ...


@dataclass(frozen=True)
class InstallEvidence:
    port: str
    launcher_version: str
    image_path: str
    image_size: int
    image_sha256: str
    command: str
    bytes_acked: int
    result: str


@dataclass(frozen=True)
class PreflightEvidence:
    port: str
    launcher_version: str
    image_size: int
    image_sha256: str
    result: str


def validate_application_image(image: bytes) -> None:
    if len(image) < 256:
        raise LauncherInstallError("image_too_small")
    if image[0] != 0xE9:
        raise LauncherInstallError("esp_image_header_missing")
    if APP_DESCRIPTION_MAGIC not in image[:1024]:
        raise LauncherInstallError("esp_application_descriptor_missing")


def _decode_line(raw: bytes) -> str:
    return raw.decode("utf-8", errors="replace").strip()


def _read_until_quiet(transport: SerialTransport, limit: int = 256) -> list[str]:
    lines: list[str] = []
    for _ in range(limit):
        raw = transport.readline()
        if not raw:
            break
        line = _decode_line(raw)
        if line:
            lines.append(line)
    return lines


def _command(transport: SerialTransport, command: str) -> list[str]:
    encoded = (command + "\n").encode("ascii")
    if transport.write(encoded) != len(encoded):
        raise LauncherInstallError("serial_command_short_write")
    transport.flush()
    return _read_until_quiet(transport)


def _detect_launcher(lines: list[str]) -> str | None:
    for line in lines:
        match = re.search(r"Launcher\s+([0-9]+(?:\.[0-9]+){1,3})", line, re.IGNORECASE)
        if match:
            return match.group(1)
    return None


def _detect_running_bridge_application(lines: list[str]) -> bool:
    return any(
        "Project name:" in line and "cardputer_bridge_firmware" in line
        or '"event":"ready"' in line and '"build_id":"cardputer-bridge' in line
        for line in lines
    )


def _synchronize_launcher(transport: SerialTransport) -> str:
    # Opening ESP32-S3 USB Serial/JTAG commonly resets the board. First try the
    # already-running console; if it is in the boot countdown, SelPress keeps
    # the device in Launcher instead of allowing an installed app to auto-boot.
    for attempt in range(12):
        version_lines = _command(transport, "version")
        version = _detect_launcher(version_lines)
        if version is not None:
            return version
        if _detect_running_bridge_application(version_lines):
            raise LauncherInstallError(
                "device_running_cardputer_bridge_power_cycle_to_launcher"
            )
        navigation_lines = _command(transport, "nav SelPress")
        if _detect_running_bridge_application(navigation_lines):
            raise LauncherInstallError(
                "device_running_cardputer_bridge_power_cycle_to_launcher"
            )
        if attempt < 11:
            time.sleep(0.35)
    raise LauncherInstallError("launcher_version_not_detected")


def _require_safe_partition_capacity(lines: list[str], image_size: int) -> None:
    if not any("Partition table" in line for line in lines):
        raise LauncherInstallError("partition_table_not_detected")
    if not any("app0" in line and "type=app" in line for line in lines):
        raise LauncherInstallError("launcher_partition_not_detected")
    free_sizes = [int(match.group(1), 16) for line in lines if (match := FREE_RANGE.search(line))]
    required = (image_size + 0xFFFF) & ~0xFFFF
    if not free_sizes or max(free_sizes) < required:
        raise LauncherInstallError("insufficient_launcher_free_range")


def _wait_for_prefix(
    transport: SerialTransport,
    prefix: str,
    limit: int = 256,
) -> str:
    for _ in range(limit):
        raw = transport.readline()
        if not raw:
            continue
        line = _decode_line(raw)
        if line.startswith("ERR"):
            raise LauncherInstallError(f"launcher_error:{line}")
        if line.startswith(prefix):
            return line
    raise LauncherInstallError(f"launcher_response_timeout:{prefix}")


def install_via_launcher(
    transport: SerialTransport,
    image: bytes,
    name: str,
    *,
    port_label: str,
    image_path: str,
) -> InstallEvidence:
    validate_application_image(image)
    if not SAFE_NAME.fullmatch(name):
        raise LauncherInstallError("unsafe_firmware_name")

    preflight = preflight_via_launcher(
        transport,
        image,
        port_label=port_label,
    )
    version = preflight.launcher_version

    command = f"flash firmware {name} {len(image)}"
    encoded_command = (command + "\n").encode("ascii")
    if transport.write(encoded_command) != len(encoded_command):
        raise LauncherInstallError("serial_flash_command_short_write")
    transport.flush()
    ready = _wait_for_prefix(transport, "READY ")
    if ready != f"READY {len(image)}":
        raise LauncherInstallError("launcher_ready_size_mismatch")

    written = 0
    while written < len(image):
        chunk = image[written : written + CHUNK_SIZE]
        if transport.write(chunk) != len(chunk):
            raise LauncherInstallError("serial_payload_short_write")
        transport.flush()
        written += len(chunk)
        ack = _wait_for_prefix(transport, "ACK ")
        if ack != f"ACK {written}/{len(image)}":
            raise LauncherInstallError(f"launcher_ack_mismatch:{ack}")

    result = _wait_for_prefix(transport, "OK flashed, rebooting")
    if result != "OK flashed, rebooting":
        raise LauncherInstallError("launcher_completion_mismatch")

    return InstallEvidence(
        port=port_label,
        launcher_version=version,
        image_path=image_path,
        image_size=len(image),
        image_sha256=hashlib.sha256(image).hexdigest(),
        command=command,
        bytes_acked=written,
        result="PASS",
    )


def preflight_via_launcher(
    transport: SerialTransport,
    image: bytes,
    *,
    port_label: str,
) -> PreflightEvidence:
    validate_application_image(image)
    transport.reset_input_buffer()
    version = _synchronize_launcher(transport)
    partitions = _command(transport, "partitions")
    _require_safe_partition_capacity(partitions, len(image))
    return PreflightEvidence(
        port=port_label,
        launcher_version=version,
        image_size=len(image),
        image_sha256=hashlib.sha256(image).hexdigest(),
        result="PASS",
    )


def _open_serial(port: str, baud: int):
    try:
        import serial
    except ImportError as exc:
        raise LauncherInstallError(
            "pyserial_missing: install with python3 -m pip install --user pyserial"
        ) from exc
    transport = serial.Serial(port=port, baudrate=baud, timeout=0.35, write_timeout=5)
    transport.dtr = False
    transport.rts = False
    time.sleep(0.25)
    return transport


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install only an application binary through M5Launcher"
    )
    parser.add_argument("--port", required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--name", default="cardbridge")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()

    try:
        image = args.image.read_bytes()
        with _open_serial(args.port, args.baud) as transport:
            if args.preflight_only:
                evidence = preflight_via_launcher(
                    transport,
                    image,
                    port_label=args.port,
                )
            else:
                evidence = install_via_launcher(
                    transport,
                    image,
                    args.name,
                    port_label=args.port,
                    image_path=str(args.image.resolve()),
                )
    except (OSError, LauncherInstallError) as exc:
        print(json.dumps({"result": "FAIL", "error": str(exc)}, ensure_ascii=False))
        return 1

    payload = asdict(evidence)
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
