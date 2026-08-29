from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SPEC_PATH = PROJECT_ROOT.parents[1] / "specs" / "Cardputer-Bridge-实现-Spec.md"
FIRMWARE_PATH = PROJECT_ROOT / "firmware" / "components" / "ble_bridge" / "ble_bridge.c"
SWIFT_PATH = (
    PROJECT_ROOT
    / "macos"
    / "Sources"
    / "CardputerBridgeCore"
    / "BLEProtocolV1.swift"
)

IMPLEMENTED_UUIDS = {
    "Bridge Service": ("s_vendor_service_uuid", "bridgeServiceUUID"),
    "Identity": ("s_identity_uuid", "identityCharacteristicUUID"),
    "Command": ("s_command_uuid", "commandCharacteristicUUID"),
    "State": ("s_state_uuid", "stateCharacteristicUUID"),
}


def canonical_uuid_from_firmware(source: str, symbol: str) -> str:
    match = re.search(
        rf"{re.escape(symbol)}\[16\]\s*=\s*\{{(?P<body>.*?)\}};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"firmware UUID symbol missing: {symbol}")
    values = bytes(int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]{2})", match["body"]))
    if len(values) != 16:
        raise AssertionError(f"firmware UUID must have 16 bytes: {symbol}")
    hex_value = bytes(reversed(values)).hex()
    return "-".join(
        [hex_value[0:8], hex_value[8:12], hex_value[12:16], hex_value[16:20], hex_value[20:32]]
    )


class BLEProtocolContractTests(unittest.TestCase):
    def test_firmware_and_swift_use_the_spec_uuid_contract(self) -> None:
        spec = SPEC_PATH.read_text(encoding="utf-8")
        firmware = FIRMWARE_PATH.read_text(encoding="utf-8")
        swift = SWIFT_PATH.read_text(encoding="utf-8")

        for label, (firmware_symbol, swift_symbol) in IMPLEMENTED_UUIDS.items():
            spec_match = re.search(
                rf"\| {re.escape(label)} \| `([0-9a-fA-F-]{{36}})` \|",
                spec,
            )
            self.assertIsNotNone(spec_match, f"spec UUID missing: {label}")
            expected = spec_match.group(1).lower()

            self.assertEqual(
                canonical_uuid_from_firmware(firmware, firmware_symbol),
                expected,
                f"firmware drifted from spec: {label}",
            )

            swift_match = re.search(
                rf"{re.escape(swift_symbol)}\s*=\s*\"([0-9a-fA-F-]{{36}})\"",
                swift,
            )
            self.assertIsNotNone(swift_match, f"Swift UUID missing: {swift_symbol}")
            self.assertEqual(
                swift_match.group(1).lower(),
                expected,
                f"Swift drifted from spec: {label}",
            )


if __name__ == "__main__":
    unittest.main()
