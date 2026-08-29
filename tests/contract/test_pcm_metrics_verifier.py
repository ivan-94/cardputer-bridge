from pathlib import Path
import unittest

from harness.verifier.pcm_metrics import verify, verify_file


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class PcmMetricsVerifierTests(unittest.TestCase):
    def test_rejects_a_non_silent_tail(self) -> None:
        fixture = PROJECT_ROOT / "harness/fixtures/invalid-pcm-metrics.json"

        result = verify_file(fixture)

        self.assertFalse(result["valid"])
        self.assertIn("tail_not_digitally_silent", result["errors"])

    def test_accepts_expected_format_pulse_and_digital_silence(self) -> None:
        result = verify(
            {
                "schema_version": 1,
                "sample_rate": 48000,
                "channels": 1,
                "sample_format": "float32",
                "duration_ms": 1000,
                "active_peak": 0.75,
                "tail_peak": 0.0,
            }
        )

        self.assertTrue(result["valid"], result["errors"])


if __name__ == "__main__":
    unittest.main()
