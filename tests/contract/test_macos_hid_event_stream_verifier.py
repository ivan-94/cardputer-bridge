from __future__ import annotations

import unittest

from harness.verifier.macos_hid_event_stream import verify_events


class MacOSHIDEventStreamVerifierTests(unittest.TestCase):
    def test_rejects_key_down_without_matching_key_up(self) -> None:
        failures = verify_events(
            [
                {
                    "v": 1,
                    "event": "macos_key",
                    "phase": "down",
                    "keycode": 12,
                    "modifiers": 0,
                }
            ],
            expected_keycode=12,
            expected_modifiers=0,
        )

        self.assertIn("macos_key_not_released", [item.code for item in failures])

    def test_accepts_one_balanced_system_key_pair(self) -> None:
        failures = verify_events(
            [
                {
                    "v": 1,
                    "event": "macos_key",
                    "phase": "down",
                    "keycode": 12,
                    "modifiers": 0x140000,
                },
                {
                    "v": 1,
                    "event": "macos_key",
                    "phase": "up",
                    "keycode": 12,
                    "modifiers": 0x140000,
                },
            ],
            expected_keycode=12,
            expected_modifiers=0x140000,
        )

        self.assertEqual([], failures)


if __name__ == "__main__":
    unittest.main()
