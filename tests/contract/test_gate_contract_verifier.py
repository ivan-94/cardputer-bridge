from pathlib import Path
import unittest

from harness.verifier.gate_contract import verify, verify_file


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class GateContractVerifierTests(unittest.TestCase):
    def test_accepts_the_ff1_executable_contract(self) -> None:
        contract = PROJECT_ROOT / "harness/contracts/ff-1.json"

        result = verify_file(contract)

        self.assertTrue(result["valid"], result["errors"])

    def test_accepts_the_ff2_executable_contract(self) -> None:
        contract = PROJECT_ROOT / "harness/contracts/ff-2.json"

        result = verify_file(contract)

        self.assertTrue(result["valid"], result["errors"])

    def test_rejects_contract_without_a_red_fixture(self) -> None:
        contract = PROJECT_ROOT / "harness/fixtures/invalid-ff1-contract.json"

        result = verify_file(contract)

        self.assertFalse(result["valid"])
        self.assertIn("red_fixture_missing", result["errors"])

    def test_rejects_system_gate_without_consent_and_recovery_controls(self) -> None:
        contract = {
            "schema_version": 1,
            "id": "FF-1",
            "requirements": ["FR-004"],
            "prerequisites": ["ff0:PASS"],
            "reset": "plugin_absent",
            "drive": ["install_plugin"],
            "observe": ["coreaudio_device_list"],
            "assertions": ["device_is_selectable"],
            "red_fixture": "invalid-plugin",
            "evidence_level": "E3",
            "human_gate": [],
            "safety": [],
        }

        result = verify(contract)

        self.assertFalse(result["valid"])
        self.assertIn("system_change_consent_missing", result["errors"])
        self.assertIn("recovery_strategy_missing", result["errors"])

    def test_rejects_contract_without_an_external_observation(self) -> None:
        contract = self.valid_ff1_contract()
        contract["observe"] = []

        result = verify(contract)

        self.assertFalse(result["valid"])
        self.assertIn("observe_missing", result["errors"])

    def test_rejects_contract_missing_an_executable_contract_field(self) -> None:
        expected_errors = {
            "requirements": "requirements_missing",
            "prerequisites": "prerequisites_missing",
            "reset": "reset_missing",
            "drive": "drive_missing",
            "assertions": "assertions_missing",
            "evidence_level": "evidence_level_invalid",
        }
        for field, expected_error in expected_errors.items():
            with self.subTest(field=field):
                contract = self.valid_ff1_contract()
                contract.pop(field)

                result = verify(contract)

                self.assertFalse(result["valid"])
                self.assertIn(expected_error, result["errors"])

    def test_rejects_an_invalid_contract_envelope(self) -> None:
        invalid_values = {
            "schema_version": (2, "schema_version_invalid"),
            "id": ("phase-one", "id_invalid"),
            "human_gate": ("Audio MIDI Setup", "human_gate_invalid"),
            "safety": ("be careful", "safety_invalid"),
        }
        for field, (value, expected_error) in invalid_values.items():
            with self.subTest(field=field):
                contract = self.valid_ff1_contract()
                contract[field] = value

                result = verify(contract)

                self.assertFalse(result["valid"])
                self.assertIn(expected_error, result["errors"])

    @staticmethod
    def valid_ff1_contract() -> dict[str, object]:
        return {
            "schema_version": 1,
            "id": "FF-1",
            "requirements": ["FR-004", "FR-011"],
            "prerequisites": ["ff0:PASS", "system_change_authorized"],
            "reset": "plugin_absent_and_consumer_stopped",
            "drive": ["install_plugin", "send_counting_pulse", "stop_producer"],
            "observe": ["coreaudio_device_list", "captured_pcm"],
            "assertions": ["device_is_selectable", "pulse_matches"],
            "red_fixture": "invalid-plugin",
            "evidence_level": "E3",
            "human_gate": ["Audio MIDI Setup visibility"],
            "safety": [
                "backup_existing_bundle",
                "idempotent_uninstall",
                "no_system_change_without_consent",
            ],
        }


if __name__ == "__main__":
    unittest.main()
