#!/usr/bin/env python3
from __future__ import annotations

import json
import plistlib
import subprocess
import sys
from pathlib import Path

AUDIO_PLUGIN_TYPE = "443ABAB8-E7B3-491A-B985-BEB9187030DB"
FACTORY_SYMBOL = "CardputerBridgeAudioFactory"


def verify(bundle: Path, probe: Path | None = None) -> dict[str, object]:
    errors: list[str] = []
    info_path = bundle / "Contents" / "Info.plist"
    if bundle.suffix != ".driver":
        errors.append("bundle_extension_invalid")
    if not info_path.is_file():
        return {"valid": False, "errors": errors + ["info_plist_missing"]}

    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundlePackageType") != "BNDL":
        errors.append("package_type_invalid")
    if info.get("CardputerBridgeAudioProtocolVersion") != 1:
        errors.append("audio_protocol_version_invalid")
    if info.get("CardputerBridgeAudioFormat") != "f32le-mono-48000":
        errors.append("audio_format_contract_invalid")
    if info.get("CardputerBridgeAudioIPC") != "unix-scm-rights-v1":
        errors.append("audio_ipc_contract_invalid")
    if info.get("CardputerBridgeAudioPeerAuth") != "getpeereid-mutual-v1":
        errors.append("peer_auth_contract_invalid")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str):
        errors.append("executable_name_missing")
        return {"valid": False, "errors": errors}

    executable = bundle / "Contents" / "MacOS" / executable_name
    if not executable.is_file():
        errors.append("executable_missing")
        return {"valid": False, "errors": errors}

    plugin_types = info.get("CFPlugInTypes", {})
    if AUDIO_PLUGIN_TYPE not in plugin_types:
        errors.append("audio_plugin_type_missing")
    factories = info.get("CFPlugInFactories", {})
    if FACTORY_SYMBOL not in factories.values():
        errors.append("factory_declaration_missing")
    audio_type_factories = plugin_types.get(AUDIO_PLUGIN_TYPE, [])
    expected_factory_ids = {
        factory_id
        for factory_id, symbol in factories.items()
        if symbol == FACTORY_SYMBOL
    }
    if (
        not isinstance(audio_type_factories, list)
        or not expected_factory_ids.intersection(audio_type_factories)
    ):
        errors.append("audio_type_factory_link_invalid")

    symbols = subprocess.run(
        ["nm", "-gU", str(executable)],
        check=False,
        capture_output=True,
        text=True,
    )
    if symbols.returncode != 0 or f"_{FACTORY_SYMBOL}" not in symbols.stdout:
        errors.append("factory_symbol_missing")

    if probe is not None and not errors:
        probe_result = subprocess.run(
            [str(probe), str(executable)],
            check=False,
            capture_output=True,
            text=True,
        )
        if probe_result.returncode != 0:
            errors.append("factory_probe_failed")

    return {"valid": not errors, "errors": errors, "bundle": str(bundle)}


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: audio_bundle.py <bundle> [factory-probe]", file=sys.stderr)
        return 64
    result = verify(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) == 3 else None)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
