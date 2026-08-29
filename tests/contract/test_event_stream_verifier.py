from pathlib import Path
import unittest

from harness.verifier.event_stream import verify_events, verify_file


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class EventStreamVerifierTests(unittest.TestCase):
    def test_rejects_capture_remaining_open_after_control_loss(self) -> None:
        fixture = PROJECT_ROOT / "harness/fixtures/invalid-control-loss.ndjson"

        failures = verify_file(fixture)

        self.assertEqual(
            ["capture_open_without_control"],
            [failure.code for failure in failures],
        )

    def test_rejects_open_capture_without_wifi_authority(self) -> None:
        failures = verify_events([self.valid_transition(wifi_audio_authenticated=False)])

        self.assertIn("capture_open_without_wifi", [failure.code for failure in failures])

    def test_rejects_open_capture_without_virtual_microphone(self) -> None:
        failures = verify_events([self.valid_transition(virtual_mic_ready=False)])

        self.assertIn("capture_open_without_virtual_mic", [failure.code for failure in failures])

    def test_rejects_missing_or_wrongly_typed_authority_fields(self) -> None:
        missing = self.valid_transition()
        del missing["ble_control_authenticated"]
        wrong_type = self.valid_transition(ble_control_authenticated=0)

        failures = verify_events([missing, wrong_type])

        self.assertEqual(
            ["event_schema_invalid"],
            list(dict.fromkeys(failure.code for failure in failures)),
        )

    @staticmethod
    def valid_transition(**overrides: object) -> dict[str, object]:
        event: dict[str, object] = {
            "v": 1,
            "event": "transition",
            "action": "toggle_mic_intent",
            "source": "harness",
            "mic_intent": "live",
            "capture_gate": "open",
            "ble_control_authenticated": True,
            "wifi_audio_authenticated": True,
            "virtual_mic_ready": True,
        }
        event.update(overrides)
        return event


if __name__ == "__main__":
    unittest.main()
