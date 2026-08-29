from __future__ import annotations

import json
import time
import unittest

from scripts.verify_firmware_boot import (
    decode_event,
    find_forbidden_boot_warnings,
    reset_usb_serial_jtag,
    wait_for_boot_event,
)


class FakeSerialReader:
    def __init__(self, lines: list[bytes]) -> None:
        self.lines = lines

    def readline(self) -> bytes:
        return self.lines.pop(0) if self.lines else b""


class FakeResettableSerial:
    def __init__(self) -> None:
        self.events: list[tuple[str, bool]] = []

    @property
    def dtr(self) -> bool:
        raise AssertionError("write-only test double")

    @dtr.setter
    def dtr(self, value: bool) -> None:
        self.events.append(("dtr", value))

    @property
    def rts(self) -> bool:
        raise AssertionError("write-only test double")

    @rts.setter
    def rts(self, value: bool) -> None:
        self.events.append(("rts", value))


class FirmwareBootVerifierTests(unittest.TestCase):
    def test_uses_usb_serial_jtag_reset_sequence(self) -> None:
        transport = FakeResettableSerial()

        reset_usb_serial_jtag(transport, settle=lambda _: None)

        self.assertEqual(
            [
                ("rts", False),
                ("dtr", False),
                ("rts", True),
                ("dtr", False),
                ("rts", False),
            ],
            transport.events,
        )

    def test_ignores_boot_noise_and_returns_structured_error(self) -> None:
        expected = {
            "v": 1,
            "event": "error",
            "code": "ble_start_failed",
            "esp_error": "ESP_ERR_INVALID_ARG",
        }
        reader = FakeSerialReader(
            [b"ESP-ROM:esp32s3-20210327\n", json.dumps(expected).encode() + b"\n"]
        )

        event, captured = wait_for_boot_event(
            reader,
            deadline=time.monotonic() + 0.05,
        )

        self.assertEqual(expected, event)
        self.assertEqual(2, len(captured))

    def test_decode_event_rejects_non_json_and_non_object_values(self) -> None:
        self.assertIsNone(decode_event(b"I (24) boot\n"))
        self.assertIsNone(decode_event(b"[1, 2, 3]\n"))

    def test_partial_advertising_warning_is_forbidden(self) -> None:
        warning = "W (1288) BT_BTM: BTM_BleWriteAdvData, Partial data write into ADV"
        self.assertEqual([warning], find_forbidden_boot_warnings(["boot", warning]))


if __name__ == "__main__":
    unittest.main()
