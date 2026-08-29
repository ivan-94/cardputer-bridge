from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest

from harness.verifier.input_event_stream import verify_events


class InputRouterScenarioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        executable = Path(sys.argv[1])
        scenario = (
            Path(__file__).resolve().parents[2]
            / "harness/fixtures/input-router-scenario.ndjson"
        )
        completed = subprocess.run(
            [str(executable)],
            check=True,
            capture_output=True,
            text=True,
            input=scenario.read_text(encoding="utf-8"),
        )
        cls.events = [
            json.loads(line) for line in completed.stdout.splitlines() if line
        ]

    def events_for(self, request_id: str) -> list[dict[str, object]]:
        return [
            event for event in self.events if event.get("request_id") == request_id
        ]

    def test_external_verifier_accepts_real_router_events(self) -> None:
        self.assertEqual([], verify_events(self.events))

    def test_plain_and_mapped_reports_are_exact(self) -> None:
        plain = self.events_for("plain-down")
        mapped = self.events_for("mapped-key-down")

        self.assertIn(
            {"v": 1, "event": "hid_report", "request_id": "plain-down", "modifiers": 0, "usage": 20},
            plain,
        )
        self.assertIn(
            {"v": 1, "event": "hid_report", "request_id": "mapped-key-down", "modifiers": 9, "usage": 20},
            mapped,
        )
        self.assertTrue(any(event["event"] == "shortcut_feedback" for event in mapped))

    def test_unmapped_chord_never_emits_hid(self) -> None:
        events = self.events_for("unmapped-key-down")

        self.assertTrue(any(event["event"] == "not_mapped" for event in events))
        self.assertFalse(any(event["event"] == "hid_report" for event in events))

    def test_only_short_g0_toggles_mic(self) -> None:
        toggles = [
            event
            for event in self.events
            if event.get("event") == "domain_action"
            and event.get("action") == "toggle_mic_intent"
        ]

        self.assertEqual(["short-g0-up"], [event["request_id"] for event in toggles])

    def test_disconnect_releases_hid_before_control_loss(self) -> None:
        events = self.events_for("disconnect")

        self.assertEqual("hid_report", events[1]["event"])
        self.assertEqual((0, 0), (events[1]["modifiers"], events[1]["usage"]))
        self.assertEqual("domain_action", events[2]["event"])
        self.assertEqual("control_link_lost", events[2]["action"])
        self.assertTrue(events[-1]["all_keys_up"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
