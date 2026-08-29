from __future__ import annotations

import unittest

from scripts.verify_hid_hil import assert_device_hid_delta


class HIDHILVerifierTests(unittest.TestCase):
    def test_accepts_one_successful_down_up_report_pair(self) -> None:
        assert_device_hid_delta(
            {
                "hid_connected": True,
                "hid_report_total": 10,
                "hid_report_failures": 0,
            },
            {
                "hid_connected": True,
                "hid_report_total": 12,
                "hid_report_failures": 0,
                "input_all_keys_up": True,
            },
        )

    def test_rejects_a_firmware_send_failure_even_if_total_increases(self) -> None:
        with self.assertRaisesRegex(AssertionError, "failure counter changed"):
            assert_device_hid_delta(
                {
                    "hid_connected": True,
                    "hid_report_total": 10,
                    "hid_report_failures": 0,
                },
                {
                    "hid_connected": True,
                    "hid_report_total": 12,
                    "hid_report_failures": 1,
                    "input_all_keys_up": True,
                },
            )

    def test_rejects_a_stuck_key_after_the_report_pair(self) -> None:
        with self.assertRaisesRegex(AssertionError, "all keys up"):
            assert_device_hid_delta(
                {
                    "hid_connected": True,
                    "hid_report_total": 10,
                    "hid_report_failures": 0,
                },
                {
                    "hid_connected": True,
                    "hid_report_total": 12,
                    "hid_report_failures": 0,
                    "input_all_keys_up": False,
                },
            )


if __name__ == "__main__":
    unittest.main()
