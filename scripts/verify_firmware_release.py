#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import sys
from typing import Any


EXPECTED_FLASH_OPTIONS = [
    "--flash_mode",
    "dio",
    "--flash_freq",
    "80m",
    "--flash_size",
    "8MB",
]
EXPECTED_OFFSETS = {"0x0", "0x8000", "0x10000"}
EXPECTED_ARTIFACT_PATHS = {
    "0x0": "bootloader/bootloader.bin",
    "0x8000": "partition_table/partition-table.bin",
    "0x10000": "cardputer_bridge_firmware.bin",
}
EXPECTED_CANDIDATE = "0.9.6-recording-led"
EXPECTED_VERIFICATION_CHECKS = {
    "flash_verified",
    "boot_hil",
    "serial_control_hil",
    "ble_heartbeat_hil",
    "hid_q_passthrough_hil",
    "config_schema_3_hil",
    "fail_closed",
    "wifi_audio_hil",
    "macos_restart_mute_hil",
    "muted_idle_restart_recovery_hil",
    "device_mic_intent_authority_hil",
    "recording_led_hil",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AssertionError("release_manifest_must_be_an_object")
    return value


def manifest_artifacts(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise AssertionError("release_artifacts_must_be_an_array")
    by_offset: dict[str, dict[str, Any]] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict) or not isinstance(artifact.get("offset"), str):
            raise AssertionError("release_artifact_invalid")
        offset = artifact["offset"]
        if offset in by_offset:
            raise AssertionError(f"release_artifact_duplicate_offset offset={offset}")
        by_offset[offset] = artifact
    if set(by_offset) != EXPECTED_OFFSETS:
        raise AssertionError(
            f"release_offsets_invalid expected={sorted(EXPECTED_OFFSETS)} actual={sorted(by_offset)}"
        )
    for offset, expected_path in EXPECTED_ARTIFACT_PATHS.items():
        if by_offset[offset].get("path") != expected_path:
            raise AssertionError(
                f"release_artifact_path_invalid offset={offset} "
                f"expected={expected_path} actual={by_offset[offset].get('path')}"
            )
    return by_offset


def parse_flash_args(path: Path) -> tuple[list[str], dict[str, str]]:
    tokens = shlex.split(path.read_text(encoding="utf-8"))
    if tokens[:6] != EXPECTED_FLASH_OPTIONS:
        raise AssertionError(f"flash_options_invalid actual={tokens[:6]}")
    pairs = tokens[6:]
    if len(pairs) % 2:
        raise AssertionError("flash_args_offset_path_pairs_invalid")
    entries = dict(zip(pairs[0::2], pairs[1::2], strict=True))
    if set(entries) != EXPECTED_OFFSETS:
        raise AssertionError(
            f"flash_args_offsets_invalid expected={sorted(EXPECTED_OFFSETS)} actual={sorted(entries)}"
        )
    return tokens[:6], entries


def verify_release(manifest_path: Path, build_dir: Path) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    required = {
        "schema_version": 1,
        "candidate": EXPECTED_CANDIDATE,
        "chip": "esp32s3",
        "flash_size_bytes": 8 * 1024 * 1024,
        "baud": 460800,
    }
    for key, expected in required.items():
        if manifest.get(key) != expected:
            raise AssertionError(
                f"release_field_invalid key={key} expected={expected!r} actual={manifest.get(key)!r}"
            )

    state = manifest.get("state")
    if state not in {"built-not-flashed", "flashed-verified"}:
        raise AssertionError(f"release_state_invalid actual={state!r}")

    verification = manifest.get("verification")
    if state == "built-not-flashed":
        if verification is not None:
            raise AssertionError("unflashed_release_must_not_claim_verification")
    else:
        if not isinstance(verification, dict):
            raise AssertionError("verified_release_requires_verification_record")
        evidence = verification.get("evidence")
        if not isinstance(evidence, str) or not evidence.endswith("/finalization.json"):
            raise AssertionError("verification_evidence_path_invalid")
        evidence_path = Path(evidence)
        if not evidence_path.is_file():
            raise AssertionError("verification_evidence_missing")
        evidence_record = load_manifest(evidence_path)
        if evidence_record.get("result") != "PASS":
            raise AssertionError("verification_evidence_not_pass")
        if evidence_record.get("candidate") != manifest["candidate"]:
            raise AssertionError("verification_evidence_candidate_mismatch")
        if evidence_record.get("completed_at") != verification.get("completed_at"):
            raise AssertionError("verification_evidence_timestamp_mismatch")
        checks = verification.get("checks")
        if not isinstance(checks, dict) or set(checks) != EXPECTED_VERIFICATION_CHECKS:
            raise AssertionError("verification_checks_invalid")
        if not all(value is True for value in checks.values()):
            raise AssertionError("verification_checks_incomplete")

    expected_runtime = manifest.get("expected_runtime")
    if expected_runtime != {
        "build_id": "cardputer-bridge-phase3",
        "config_schema": 3,
        "mic_intent": "muted",
        "capture_gate": "closed",
    }:
        raise AssertionError("release_runtime_contract_invalid")

    artifacts = manifest_artifacts(manifest)
    if state == "flashed-verified" and verification["firmware_sha256"] != artifacts["0x10000"]["sha256"]:
        raise AssertionError("verification_firmware_hash_mismatch")
    if state == "flashed-verified":
        if evidence_record.get("firmware_sha256") != artifacts["0x10000"]["sha256"]:
            raise AssertionError("verification_evidence_firmware_hash_mismatch")
        if evidence_record.get("checks") != verification["checks"]:
            raise AssertionError("verification_evidence_checks_mismatch")
    flash_args_record = manifest.get("flash_args")
    if not isinstance(flash_args_record, dict):
        raise AssertionError("release_flash_args_record_invalid")
    flash_args_path = build_dir / str(flash_args_record.get("path"))
    records = [*artifacts.values(), flash_args_record]
    for record in records:
        artifact_path = build_dir / str(record.get("path"))
        if not artifact_path.is_file():
            raise AssertionError(f"release_artifact_missing path={artifact_path}")
        actual_bytes = artifact_path.stat().st_size
        actual_hash = sha256(artifact_path)
        if actual_bytes != record.get("bytes"):
            raise AssertionError(
                f"release_artifact_size_mismatch path={artifact_path} "
                f"expected={record.get('bytes')} actual={actual_bytes}"
            )
        if actual_hash != record.get("sha256"):
            raise AssertionError(
                f"release_artifact_hash_mismatch path={artifact_path} "
                f"expected={record.get('sha256')} actual={actual_hash}"
            )

    _, flash_entries = parse_flash_args(flash_args_path)
    for offset, relative_path in flash_entries.items():
        if relative_path != artifacts[offset].get("path"):
            raise AssertionError(
                f"flash_args_path_mismatch offset={offset} "
                f"expected={artifacts[offset].get('path')} actual={relative_path}"
            )

    return {
        "result": "PASS",
        "candidate": manifest["candidate"],
        "state": state,
        "firmware_bytes": artifacts["0x10000"]["bytes"],
        "firmware_sha256": artifacts["0x10000"]["sha256"],
        "build_dir": str(build_dir),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify an exact Cardputer Bridge firmware release candidate."
    )
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify_release(args.manifest, args.build_dir)
    except (AssertionError, OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"result": "FAIL", "error": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
