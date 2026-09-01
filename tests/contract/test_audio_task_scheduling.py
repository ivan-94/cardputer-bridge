import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
AUDIO_TASK = PROJECT_ROOT / "firmware/components/device_audio/device_audio.cpp"


class AudioTaskSchedulingContractTests(unittest.TestCase):
    def test_sub_tick_delays_do_not_collapse_to_zero(self) -> None:
        source = AUDIO_TASK.read_text(encoding="utf-8")
        short_delay_conversions = re.findall(
            r"pdMS_TO_TICKS\((\d+)\)",
            source,
        )

        self.assertFalse(
            [value for value in short_delay_conversions if int(value) < 10],
            "Sub-tick millisecond delays can collapse to zero; short waits must "
            "use at least one explicit tick so the idle task can run.",
        )
        self.assertRegex(
            source,
            r"while \(M5\.Mic\.isRecording\(\) == sample_buffers\.size\(\)\) "
            r"\{\s*vTaskDelay\(1\);",
        )

    def test_capture_never_waits_for_network_or_encryption(self) -> None:
        source = AUDIO_TASK.read_text(encoding="utf-8")
        capture = source[
            source.index("void audio_capture_task(void*)"):
            source.index("void audio_transport_task(void*)")
        ]

        self.assertIn("s_capture_ring.try_push(frame)", capture)
        self.assertIn("!s_capture_enabled.load", capture)
        self.assertIn("!s_receiver_ready.load", capture)
        for forbidden in ("send(", "connect(", "socket(", "psa_aead_encrypt"):
            self.assertNotIn(forbidden, capture)

    def test_reliable_stream_is_bounded_and_lower_priority_than_capture(self) -> None:
        source = AUDIO_TASK.read_text(encoding="utf-8")

        self.assertIn("kCaptureRingFrames = 20", source)
        self.assertIn("SOCK_STREAM", source)
        self.assertIn("TCP_NODELAY", source)
        self.assertIn("SO_SNDTIMEO", source)
        self.assertGreaterEqual(source.count("if (setsockopt("), 2)
        self.assertRegex(source, r"kCaptureTaskPriority = (\d+)")
        self.assertRegex(source, r"kTransportTaskPriority = (\d+)")
        capture_priority = int(
            re.search(r"kCaptureTaskPriority = (\d+)", source).group(1)
        )
        transport_priority = int(
            re.search(r"kTransportTaskPriority = (\d+)", source).group(1)
        )
        self.assertGreater(capture_priority, transport_priority)


if __name__ == "__main__":
    unittest.main()
