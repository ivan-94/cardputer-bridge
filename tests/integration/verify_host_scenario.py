from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest

from harness.verifier.event_stream import verify_events


class HostScenarioTests(unittest.TestCase):
    def test_real_domain_scenario_fails_closed_when_control_is_lost(self) -> None:
        executable = Path(sys.argv[1])
        scenario = Path(__file__).resolve().parents[2] / "harness/fixtures/host-scenario.ndjson"
        completed = subprocess.run(
            [str(executable)],
            check=True,
            capture_output=True,
            text=True,
            input=scenario.read_text(encoding="utf-8"),
        )
        events = [json.loads(line) for line in completed.stdout.splitlines() if line]

        self.assertEqual([], verify_events(events))
        self.assertEqual("ready", events[0]["event"])
        transitions = [event for event in events if event["event"] == "transition"]
        snapshots = [event for event in events if event["event"] == "snapshot"]
        self.assertEqual("control_link_lost", transitions[-1]["action"])
        self.assertEqual("muted", transitions[-1]["mic_intent"])
        self.assertEqual("closed", transitions[-1]["capture_gate"])
        self.assertFalse(transitions[-1]["ble_control_authenticated"])
        self.assertEqual(3, len(snapshots))
        comparable_keys = {
            "profile",
            "mic_intent",
            "capture_gate",
            "ble_control_authenticated",
            "wifi_audio_authenticated",
            "virtual_mic_ready",
        }
        self.assertEqual(
            {key: snapshots[1][key] for key in comparable_keys},
            {key: snapshots[2][key] for key in comparable_keys},
        )

    def test_unsupported_action_is_observable_and_returns_nonzero(self) -> None:
        executable = Path(sys.argv[1])
        fixture = Path(__file__).resolve().parents[2] / "harness/fixtures/invalid-command.ndjson"

        completed = subprocess.run(
            [str(executable)],
            check=False,
            capture_output=True,
            text=True,
            input=fixture.read_text(encoding="utf-8"),
        )
        events = [json.loads(line) for line in completed.stdout.splitlines() if line]

        self.assertEqual(1, completed.returncode)
        self.assertEqual("error", events[-1]["event"])
        self.assertEqual("dispatch_unsupported", events[-1]["code"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
