from pathlib import Path
import re
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SDKCONFIG_DEFAULTS = PROJECT_ROOT / "firmware" / "sdkconfig.defaults"


class MainTaskStackContractTests(unittest.TestCase):
    def test_main_task_has_headroom_for_m5_initialization_and_bridge_state(self) -> None:
        source = SDKCONFIG_DEFAULTS.read_text(encoding="utf-8")
        match = re.search(r"^CONFIG_ESP_MAIN_TASK_STACK_SIZE=(\d+)$", source, re.MULTILINE)
        self.assertIsNotNone(match, "main task stack size must be explicit")
        self.assertGreaterEqual(
            int(match.group(1)),
            8192,
            "M5.begin plus bridge locals exceeded the ESP-IDF 3584-byte default on hardware",
        )


if __name__ == "__main__":
    unittest.main()
