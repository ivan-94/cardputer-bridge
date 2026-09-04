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

    def test_realtime_audio_pipeline_is_pinned_and_ordered_by_deadline(self) -> None:
        source = AUDIO_TASK.read_text(encoding="utf-8")

        self.assertIn("kCaptureRingFrames = 10", source)
        self.assertIn("SOCK_DGRAM", source)
        self.assertIn("IPPROTO_UDP", source)
        self.assertIn("O_NONBLOCK", source)
        self.assertNotIn("SOCK_STREAM", source)
        self.assertNotIn("send_all", source)
        self.assertRegex(source, r"kCaptureTaskPriority = (\d+)")
        self.assertRegex(source, r"kTransportTaskPriority = (\d+)")
        capture_priority = int(
            re.search(r"kCaptureTaskPriority = (\d+)", source).group(1)
        )
        transport_priority = int(
            re.search(r"kTransportTaskPriority = (\d+)", source).group(1)
        )
        microphone_priority = int(
            re.search(r"kMicrophoneTaskPriority = (\d+)", source).group(1)
        )
        self.assertGreater(microphone_priority, transport_priority)
        self.assertGreater(transport_priority, capture_priority)
        self.assertIn("microphone_config.task_pinned_core = kCaptureTaskCore", source)
        self.assertIn("kCaptureTaskCore = 1", source)
        self.assertIn("kTransportTaskCore = 1", source)


if __name__ == "__main__":
    unittest.main()
