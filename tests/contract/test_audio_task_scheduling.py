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


if __name__ == "__main__":
    unittest.main()
