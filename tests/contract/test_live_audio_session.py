import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/verify_live_audio_session.py"
spec = importlib.util.spec_from_file_location("live_audio_session", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LiveAudioSessionTests(unittest.TestCase):
    def setUp(self):
        self.device = dict(stream_frames_sent=103, stream_failures=0, capture_overruns=0,
            mic_intent="live", capture_gate="open", physical_ble_authenticated=True,
            control_authenticated=True, wifi_connected=True, audio_receiver_ready=True)
        self.baseline = dict(self.device, stream_frames_sent=3)
        self.audio = dict(session_id="session", accepted_packets=103,
            missing_packets=0, duplicate_or_late_packets=0)

    def check(self, device=None, audio=None):
        return module.health_failure(self.device if device is None else device,
            self.baseline, self.audio if audio is None else audio, self.audio)

    def test_healthy_session(self):
        self.assertIsNone(self.check())

    def test_slow_capture_is_not_a_pass_even_without_sequence_gaps(self):
        self.assertEqual(module.progress_failure(2814, 2814, 60),
            "insufficient_real_audio_progress")
        self.assertIsNone(module.progress_failure(2995, 2990, 60))
        self.assertEqual(module.progress_failure(3000, 2800, 60),
            "insufficient_real_audio_progress")

    def test_still_live_is_not_success_when_capture_frames_were_lost(self):
        self.assertEqual(self.check(dict(self.device, capture_overruns=61)), "captured_audio_dropped")

    def test_mic_pause_and_transport_failure_are_failures(self):
        self.assertEqual(self.check(dict(self.device, capture_gate="closed")), "microphone_paused")
        self.assertEqual(self.check(dict(self.device, stream_failures=1)), "audio_transport_failed")

    def test_missing_counters_are_not_treated_as_zero(self):
        incomplete = dict(self.device)
        del incomplete["capture_overruns"]
        self.assertEqual(self.check(incomplete), "missing_counter:capture_overruns")

    def test_reboot_stale_probe_rotation_and_mac_loss_fail(self):
        self.assertEqual(self.check(dict(self.device, stream_frames_sent=0)), "counter_reset:stream_frames_sent")
        self.assertEqual(self.check(audio={}), "mac_probe_stale_or_missing")
        self.assertEqual(self.check(audio=dict(self.audio, session_id="other")), "audio_session_rotated")
        self.assertEqual(self.check(audio=dict(self.audio, missing_packets=1)), "mac_audio_discontinuity:missing_packets")

    def test_probe_from_previous_process_or_stalled_process_is_not_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "probe.json"
            path.write_text(json.dumps(self.audio))
            now = time.time()
            os.utime(path, (now - 10, now - 10))
            self.assertEqual(module.fresh_probe(path, now - 30, now), {})
            self.assertEqual(module.fresh_probe(path, now, now), {})
            os.utime(path, (now, now))
            self.assertEqual(module.fresh_probe(path, now - 1, now), self.audio)


if __name__ == "__main__":
    unittest.main()
