import struct
import tempfile
from pathlib import Path
import unittest

from harness.verifier.pcm_raw import verify_counting_pulse_and_silence, verify_silence


class PCMRawVerifierTests(unittest.TestCase):
    def test_rejects_non_silent_float32_capture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.f32le"
            capture.write_bytes(struct.pack("<4f", 0.0, 0.0, 0.01, 0.0))
            result = verify_silence(capture)

        self.assertFalse(result["valid"])
        self.assertIn("non_silent_sample", result["errors"])

    def test_accepts_only_digitally_silent_float32_capture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.f32le"
            capture.write_bytes(struct.pack("<128f", *([0.0] * 128)))
            result = verify_silence(capture)

        self.assertTrue(result["valid"])
        self.assertEqual(0.0, result["peak"])

    def test_rejects_non_finite_float32_capture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.f32le"
            capture.write_bytes(struct.pack("<3f", 0.0, float("nan"), 0.0))
            result = verify_silence(capture)

        self.assertFalse(result["valid"])
        self.assertIn("non_finite_sample", result["errors"])

    def test_accepts_deterministic_counting_pulse_followed_by_silence(self) -> None:
        pulse = [
            sign
            for block in range(8)
            for sign in ([0.5 if block % 2 == 0 else -0.5] * 240)
        ]
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.f32le"
            samples = ([0.0] * 120) + pulse + ([0.0] * 480)
            capture.write_bytes(struct.pack(f"<{len(samples)}f", *samples))
            result = verify_counting_pulse_and_silence(capture)

        self.assertTrue(result["valid"])
        self.assertEqual(len(pulse), result["pulse_frames"])

    def test_rejects_noise_that_only_has_peak_and_silent_tail(self) -> None:
        noise = [0.25 if index % 3 else -0.31 for index in range(1920)]
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "capture.f32le"
            samples = noise + ([0.0] * 480)
            capture.write_bytes(struct.pack(f"<{len(samples)}f", *samples))
            result = verify_counting_pulse_and_silence(capture)

        self.assertFalse(result["valid"])
        self.assertIn("counting_pulse_shape_invalid", result["errors"])


if __name__ == "__main__":
    unittest.main()
