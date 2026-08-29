#!/usr/bin/env python3
"""Create the canonical, Ed25519-signed Cardputer Bridge release manifest."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


def artifact(role: str, path: Path, url: str, offset: str | None) -> dict:
    data = path.read_bytes()
    result = {
        "bytes": len(data),
        "role": role,
        "sha256": hashlib.sha256(data).hexdigest(),
        "url": url,
    }
    if offset is not None:
        result["offset"] = offset
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--signing-key", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--published-at",
        required=True,
        help="Immutable ISO-8601 UTC timestamp, normally the tagged commit time",
    )
    args = parser.parse_args()

    tag = f"v{args.version}"
    base = (
        "https://github.com/ivan-94/cardputer-bridge/releases/"
        f"download/{tag}"
    )
    paths = {
        "factory": args.build_dir / "cardputer_bridge_firmware.bin",
        "otadata": args.build_dir / "ota_data_initial.bin",
        "partition_table": args.build_dir / "partition_table/partition-table.bin",
        "bootloader": args.build_dir / "bootloader/bootloader.bin",
    }
    for path in paths.values():
        if not path.is_file():
            raise SystemExit(f"missing release artifact: {path}")

    payload = {
        "channel": "stable",
        "firmware": {
            "chip": "esp32s3",
            "layout_version": 2,
            "ota": artifact(
                "ota",
                paths["factory"],
                f"{base}/cardputer_bridge_firmware.bin",
                None,
            ),
            "usb": [
                artifact("factory", paths["factory"], f"{base}/cardputer_bridge_firmware.bin", "0x10000"),
                artifact("otadata", paths["otadata"], f"{base}/ota_data_initial.bin", "0x610000"),
                artifact("partition_table", paths["partition_table"], f"{base}/partition-table.bin", "0x8000"),
                artifact("bootloader", paths["bootloader"], f"{base}/bootloader.bin", "0x0"),
            ],
        },
        "minimum_macos_app_version": "0.2.0",
        "product": "cardputer-bridge",
        "published_at": args.published_at,
        "schema_version": 2,
        "version": args.version,
    }
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    with tempfile.TemporaryDirectory() as temporary:
        payload_path = Path(temporary) / "payload.json"
        signature_path = Path(temporary) / "signature.bin"
        payload_path.write_bytes(canonical)
        subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-sign",
                "-rawin",
                "-inkey",
                str(args.signing_key),
                "-in",
                str(payload_path),
                "-out",
                str(signature_path),
            ],
            check=True,
        )
        signature = base64.b64encode(signature_path.read_bytes()).decode()
    manifest = {
        "payload": payload,
        "signature": {
            "algorithm": "ed25519",
            "key_id": "release-2026-01",
            "value": signature,
        },
    }
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )


if __name__ == "__main__":
    main()
