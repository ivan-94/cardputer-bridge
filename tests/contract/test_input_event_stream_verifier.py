from pathlib import Path
import unittest

from harness.verifier.input_event_stream import verify_events, verify_file


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class InputEventStreamVerifierTests(unittest.TestCase):
    def test_rejects_a_stuck_hid_report_even_when_snapshot_claims_release(self) -> None:
        fixture = PROJECT_ROOT / "harness/fixtures/invalid-hid-events.ndjson"

        failures = verify_file(fixture)
        codes = [failure.code for failure in failures]

        self.assertIn("snapshot_hid_state_mismatch", codes)
        self.assertIn("hid_not_released", codes)

    def test_rejects_shortcut_feedback_without_matching_report(self) -> None:
        failures = verify_events(
            [
                {"v": 1, "event": "ready"},
                {
                    "v": 1,
                    "event": "shortcut_feedback",
                    "request_id": "shortcut",
                    "trigger_usage": 20,
                    "modifiers": 9,
                    "usage": 20,
                },
            ]
        )

        self.assertIn(
            "shortcut_feedback_without_matching_hid",
            [failure.code for failure in failures],
        )

    def test_accepts_a_balanced_plain_key(self) -> None:
        failures = verify_events(
            [
                {"v": 1, "event": "ready"},
                {
                    "v": 1,
                    "event": "input_action",
                    "request_id": "down",
                    "action": "key_down",
                    "usage": 20,
                    "modifiers": 0,
                    "at_ms": 1,
                },
                {
                    "v": 1,
                    "event": "hid_report",
                    "request_id": "down",
                    "modifiers": 0,
                    "usage": 20,
                },
                {
                    "v": 1,
                    "event": "input_snapshot",
                    "request_id": "down",
                    "all_keys_up": False,
                    "g0_active": False,
                },
                {
                    "v": 1,
                    "event": "input_action",
                    "request_id": "up",
                    "action": "key_up",
                    "usage": 20,
                    "modifiers": 0,
                    "at_ms": 2,
                },
                {
                    "v": 1,
                    "event": "hid_report",
                    "request_id": "up",
                    "modifiers": 0,
                    "usage": 0,
                },
                {
                    "v": 1,
                    "event": "input_snapshot",
                    "request_id": "up",
                    "all_keys_up": True,
                    "g0_active": False,
                },
            ]
        )

        self.assertEqual([], failures)


if __name__ == "__main__":
    unittest.main()
