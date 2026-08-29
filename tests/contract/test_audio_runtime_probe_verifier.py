import unittest

from harness.verifier.audio_runtime_probe import verify, verify_readiness


class AudioRuntimeProbeVerifierTests(unittest.TestCase):
    def test_readiness_does_not_require_packets_while_safely_muted(self) -> None:
        result = verify_readiness(
            {
                "status": "listening",
                "accepted_packets": 0,
                "listener_port": 49152,
                "session_id": "0123456789abcdef",
                "system_microphone_ready": True,
            }
        )

        self.assertTrue(result["valid"], result["errors"])

    def test_accepts_authenticated_device_test_packets(self) -> None:
        result = verify(
            {
                "status": "receiving",
                "accepted_packets": 3,
                "missing_packets": 0,
                "duplicate_or_late_packets": 0,
                "listener_ipv4": "192.168.2.109",
                "listener_port": 49152,
                "session_id": "0123456789abcdef",
                "signal_level": 0,
            }
        )

        self.assertTrue(result["valid"], result["errors"])

    def test_rejects_listener_only_fault_or_unbounded_loss(self) -> None:
        result = verify(
            {
                "status": "listening",
                "accepted_packets": 0,
                "missing_packets": 12,
                "duplicate_or_late_packets": 0,
                "fault": "audio_packet_rejected_authenticationFailed",
            }
        )

        self.assertFalse(result["valid"])
        self.assertIn("authenticated_packets_missing", result["errors"])
        self.assertIn("receiver_fault_present", result["errors"])


if __name__ == "__main__":
    unittest.main()
