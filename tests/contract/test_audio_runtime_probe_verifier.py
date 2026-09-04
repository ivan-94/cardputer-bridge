import unittest

from harness.verifier.audio_runtime_probe import verify, verify_readiness


class AudioRuntimeProbeVerifierTests(unittest.TestCase):
    def test_readiness_does_not_require_packets_while_safely_muted(self) -> None:
        result = verify_readiness(
            {
                "status": "listening",
                "transport": "udp",
                "audio_format": "pcm16le-v2",
                "audio_encrypted": False,
                "accepted_packets": 0,
                "listener_port": 49152,
                "session_id": "0123456789abcdef",
                "system_microphone_ready": True,
            }
        )

        self.assertTrue(result["valid"], result["errors"])

    def test_accepts_valid_device_test_packets(self) -> None:
        result = verify(
            {
                "status": "receiving",
                "transport": "udp",
                "audio_format": "pcm16le-v2",
                "audio_encrypted": False,
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
                "transport": "udp",
                "audio_format": "pcm16le-v2",
                "audio_encrypted": False,
                "accepted_packets": 0,
                "missing_packets": 12,
                "duplicate_or_late_packets": 0,
                "fault": "audio_packet_rejected_invalidHeader",
            }
        )

        self.assertFalse(result["valid"])
        self.assertIn("accepted_packets_missing", result["errors"])
        self.assertIn("receiver_fault_present", result["errors"])

    def test_legacy_udp_probe_cannot_pass_new_protocol_gate(self) -> None:
        probe = dict(status="listening", transport="udp", listener_port=49152,
                     session_id="0123456789abcdef", system_microphone_ready=True)
        self.assertIn("plaintext_v2_format_missing", verify_readiness(probe)["errors"])
        self.assertIn("plaintext_v2_format_missing", verify(probe)["errors"])

    def test_rejects_even_one_missing_or_duplicate_stream_frame(self) -> None:
        result = verify(
            {
                "status": "receiving",
                "transport": "udp",
                "audio_format": "pcm16le-v2",
                "audio_encrypted": False,
                "accepted_packets": 100,
                "missing_packets": 1,
                "duplicate_or_late_packets": 1,
                "listener_port": 49152,
                "session_id": "0123456789abcdef",
            }
        )

        self.assertFalse(result["valid"])
        self.assertIn("stream_sequence_gap", result["errors"])
        self.assertIn("stream_duplicate_or_late", result["errors"])


if __name__ == "__main__":
    unittest.main()
