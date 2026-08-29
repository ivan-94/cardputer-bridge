from __future__ import annotations

import unittest
from unittest import mock

from scripts import verify_runtime_hil


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class RuntimeHILHeartbeatWaitTests(unittest.TestCase):
    def test_returns_as_soon_as_the_real_counter_advances(self) -> None:
        clock = FakeClock()
        states = [
            {"ble_heartbeat_total": 4, "physical_ble_authenticated": True},
            {"ble_heartbeat_total": 4, "physical_ble_authenticated": True},
            {"ble_heartbeat_total": 5, "physical_ble_authenticated": True},
        ]
        with (
            mock.patch.object(verify_runtime_hil, "send_command", side_effect=states),
            mock.patch.object(verify_runtime_hil.time, "monotonic", clock.monotonic),
            mock.patch.object(verify_runtime_hil.time, "sleep", clock.sleep),
        ):
            result = verify_runtime_hil.verify_ble_heartbeat(object(), 12)

        self.assertEqual(5, result["ble_heartbeat_total"])
        self.assertEqual(1.0, clock.now)

    def test_fails_when_counter_never_advances_before_deadline(self) -> None:
        clock = FakeClock()
        unchanged = {
            "ble_heartbeat_total": 4,
            "physical_ble_authenticated": True,
        }
        with (
            mock.patch.object(
                verify_runtime_hil,
                "send_command",
                return_value=unchanged,
            ),
            mock.patch.object(verify_runtime_hil.time, "monotonic", clock.monotonic),
            mock.patch.object(verify_runtime_hil.time, "sleep", clock.sleep),
        ):
            with self.assertRaisesRegex(
                AssertionError,
                "app heartbeat did not reach firmware",
            ):
                verify_runtime_hil.verify_ble_heartbeat(object(), 2)

        self.assertEqual(2.0, clock.now)


if __name__ == "__main__":
    unittest.main()
