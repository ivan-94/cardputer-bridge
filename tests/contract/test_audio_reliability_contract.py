import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RECEIVER = (
    PROJECT_ROOT
    / "macos/Sources/CardputerBridgeApp/AudioReceiverController.swift"
)
HIL = PROJECT_ROOT / "scripts/verify_audio_hil.py"
PHASE3 = PROJECT_ROOT / "scripts/verify-phase-3.sh"
SDKCONFIG_DEFAULTS = PROJECT_ROOT / "firmware/sdkconfig.defaults"


class AudioReliabilityContractTests(unittest.TestCase):
    def test_hil_default_proves_a_full_minute_without_gaps(self) -> None:
        hil = HIL.read_text(encoding="utf-8")
        phase3 = PHASE3.read_text(encoding="utf-8")

        self.assertIn(
            'parser.add_argument("--capture-seconds", type=float, default=60.0)',
            hil,
        )
        self.assertIn('CARDPUTER_PHASE3_CAPTURE_SECONDS:-60', phase3)
        self.assertIn("if missing_growth != 0", hil)
        self.assertIn("if duplicate_growth != 0", hil)
        self.assertIn("if stream_failure_growth != 0", hil)
        self.assertIn("if capture_overrun_growth != 0", hil)

    def test_hidden_tcp_queue_is_bounded(self) -> None:
        defaults = SDKCONFIG_DEFAULTS.read_text(encoding="utf-8")

        self.assertIn("CONFIG_LWIP_TCP_SND_BUF_DEFAULT=2880", defaults)

    def test_candidate_cannot_replace_stream_before_key_proof(self) -> None:
        source = RECEIVER.read_text(encoding="utf-8")
        accept = source[
            source.index("private func accept("):
            source.index("private func remove(")
        ]
        authenticate = source[
            source.index("private func authenticateCandidate("):
            source.index("private func consumeAuthenticated(")
        ]

        self.assertNotIn("connections.removeAll()", accept)
        self.assertIn("frame.flags.contains(.test)", authenticate)
        self.assertIn("frame.flags.contains(.muted)", authenticate)
        self.assertIn("guard frames.count == 3", authenticate)
        self.assertIn("first.sequence < expected", authenticate)
        self.assertIn("queue.asyncAfter(deadline: .now() + 1)", source)
        self.assertLess(
            authenticate.index("guard frames.count == 3"),
            authenticate.index("activeConnectionID = identifier"),
        )

    def test_probe_and_ui_publication_are_throttled(self) -> None:
        source = RECEIVER.read_text(encoding="utf-8")

        self.assertIn("streamPublishIntervalNanoseconds: UInt64 = 100_000_000", source)
        self.assertIn("timer.schedule(deadline: .now() + 2, repeating: 2)", source)
        self.assertNotRegex(source, r"publishStreamProgress\(force:")
        self.assertIn("pendingStreamFault", source)

    def test_sequence_evidence_survives_audio_pipeline_reset(self) -> None:
        source = RECEIVER.read_text(encoding="utf-8")
        reset = source[
            source.index("private func resetAudioPipeline()"):
            source.index("private var currentMetrics")
        ]

        self.assertNotIn("authenticatedMissingCount", reset)
        self.assertNotIn("authenticatedDuplicateOrLateCount", reset)
        self.assertRegex(
            source,
            re.compile(
                r"current\.missingPackets = authenticatedMissingCount.*"
                r"current\.duplicateOrLatePackets = "
                r"authenticatedDuplicateOrLateCount",
                re.DOTALL,
            ),
        )


if __name__ == "__main__":
    unittest.main()
