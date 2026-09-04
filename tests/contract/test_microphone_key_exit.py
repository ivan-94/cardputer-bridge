from pathlib import Path
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
MAIN_SOURCE = PROJECT_ROOT / "firmware" / "main" / "main.cpp"
INPUT_HEADER = (
    PROJECT_ROOT
    / "firmware"
    / "components"
    / "cardputer_input"
    / "include"
    / "cardputer_adv_input.hpp"
)
INPUT_SOURCE = (
    PROJECT_ROOT
    / "firmware"
    / "components"
    / "cardputer_input"
    / "cardputer_adv_input.cpp"
)


class MicrophoneKeyExitContractTests(unittest.TestCase):
    def test_every_physical_key_can_mute_and_still_be_forwarded(self) -> None:
        main = MAIN_SOURCE.read_text(encoding="utf-8")
        header = INPUT_HEADER.read_text(encoding="utf-8")
        input_source = INPUT_SOURCE.read_text(encoding="utf-8")

        self.assertIn("physical_press_observed() const", header)
        self.assertIn(
            "physical_press_observed_ || physical.pressed",
            input_source,
        )
        self.assertIn("stop_microphone_for_physical_press", main)
        self.assertIn("keyboard.physical_press_observed()", main)
        self.assertIn(
            "domain.state().capture_gate == cardbridge::CaptureGate::kOpen",
            main,
        )
        self.assertIn(
            "should_forward_after_microphone_stop(\n"
            "                    keyboard_stopped_microphone,\n"
            "                    event.pressed",
            main,
        )
        self.assertIn('"ANY KEY  mute microphone"', main)
        self.assertIn("cardbridge::G0RecordingStopGuard", main)
        self.assertIn("g0_recording_stop_guard.recording_started(now)", main)
        self.assertIn("g0_recording_stop_guard.stop_armed()", main)
        self.assertIn("activation_g0_press_ignored", main)
        self.assertIn(
            "const bool activation_transaction_active =",
            main,
        )

        g0_start = main.index("if (M5.BtnA.wasPressed())")
        g0_end = main.index("if (M5.BtnA.wasReleased())", g0_start)
        g0_path = main[g0_start:g0_end]
        self.assertLess(
            g0_path.index("stop_microphone_for_physical_press"),
            g0_path.index("pairing.visible"),
            "recording stop must take priority over pairing confirmation",
        )


if __name__ == "__main__":
    unittest.main()
