import unittest
import tempfile
from pathlib import Path
import xml.etree.ElementTree as ET

from harness.runners.run_suite import (
    build_coverage,
    build_source_manifest,
    reconcile_suite_coverage,
    verdict_for_exit_code,
    write_junit,
)


class EvidenceManifestTests(unittest.TestCase):
    def test_exit_codes_preserve_blocked_and_human_gate_states(self) -> None:
        self.assertEqual("PASS", verdict_for_exit_code(0))
        self.assertEqual("FAIL", verdict_for_exit_code(1))
        self.assertEqual("BLOCKED", verdict_for_exit_code(2))
        self.assertEqual("HUMAN_GATE", verdict_for_exit_code(3))
        self.assertEqual("FAIL", verdict_for_exit_code(70))

    def test_junit_does_not_report_blocked_as_a_normal_failure_or_pass(self) -> None:
        result = {
            "command": ["verify-ff-1.sh"],
            "duration_ms": 12,
            "exit_code": 2,
        }
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "junit.xml"
            write_junit(report, "ff1", [result])
            root = ET.parse(report).getroot()

        self.assertEqual("0", root.attrib["failures"])
        self.assertEqual("1", root.attrib["errors"])
        self.assertIsNotNone(root.find("./testcase/error"))

    def test_preflight_coverage_does_not_claim_ff1_product_requirements(self) -> None:
        coverage = build_coverage(
            "ff1-preflight",
            "build-id",
            [{"exit_code": 0, "evidence": "commands.log#command-1"}],
        )

        self.assertEqual("NOT_RUN", coverage["gate"]["verdict"])
        self.assertEqual(
            {"FR-004": "NOT_RUN", "FR-011": "NOT_RUN"},
            {item["id"]: item["verdict"] for item in coverage["requirements"]},
        )
        self.assertEqual("PASS", coverage["preflight"][0]["verdict"])
        self.assertEqual("PASS", coverage["suite_verdict"])

    def test_blocked_ff1_coverage_keeps_requirements_not_run(self) -> None:
        coverage = build_coverage(
            "ff1",
            "build-id",
            [
                {"exit_code": 0, "evidence": "commands.log#command-1"},
                {"exit_code": 2, "evidence": "commands.log#command-2"},
            ],
        )

        self.assertEqual("BLOCKED", coverage["gate"]["verdict"])
        self.assertTrue(
            all(item["verdict"] == "NOT_RUN" for item in coverage["requirements"])
        )

    def test_ff2_preflight_cannot_claim_cardputer_e4(self) -> None:
        coverage = build_coverage(
            "ff2-preflight",
            "build-id",
            [{"exit_code": 0, "evidence": "commands.log#command-1"}],
        )

        self.assertEqual("PASS", coverage["suite_verdict"])
        self.assertEqual("NOT_RUN", coverage["gate"]["verdict"])
        self.assertEqual(
            {"FR-001": "NOT_RUN", "FR-002": "NOT_RUN", "FR-003": "NOT_RUN"},
            {item["id"]: item["verdict"] for item in coverage["requirements"]},
        )

    def test_ff2_cannot_pass_without_e4_assertion_evidence(self) -> None:
        results, status, coverage = reconcile_suite_coverage(
            "ff2",
            "build-id",
            [{"exit_code": 0, "evidence": "commands.log#command-1"}],
            overall_status=0,
            source_stale=False,
        )

        self.assertEqual(1, status)
        self.assertEqual("FAIL", coverage["gate"]["verdict"])
        self.assertEqual("coverage-completeness", results[-1]["command"][0])

    def test_ff2_machine_pass_can_end_at_an_explicit_physical_human_gate(self) -> None:
        coverage = build_coverage(
            "ff2",
            "build-id",
            [
                {"exit_code": 0, "evidence": "commands.log#command-1"},
                {"exit_code": 3, "evidence": "commands.log#command-2"},
            ],
        )

        self.assertEqual("HUMAN_GATE", coverage["suite_verdict"])
        self.assertEqual("HUMAN_GATE", coverage["gate"]["verdict"])
        self.assertTrue(
            all(item["verdict"] == "NOT_RUN" for item in coverage["requirements"])
        )

    def test_ff1_cannot_pass_without_per_assertion_evidence(self) -> None:
        coverage = build_coverage(
            "ff1",
            "build-id",
            [{"exit_code": 0, "evidence": "commands.log#command-1"}],
        )

        self.assertEqual("FAIL", coverage["gate"]["verdict"])
        self.assertEqual("FAIL", coverage["suite_verdict"])
        self.assertTrue(
            all(item["evidence"] is None for item in coverage["requirements"])
        )

    def test_ff1_runner_downgrades_a_command_pass_when_coverage_is_incomplete(self) -> None:
        results, status, coverage = reconcile_suite_coverage(
            "ff1",
            "build-id",
            [{"exit_code": 0, "evidence": "commands.log#command-1"}],
            overall_status=0,
            source_stale=False,
        )

        self.assertEqual(1, status)
        self.assertEqual("FAIL", coverage["suite_verdict"])
        self.assertEqual("FAIL", coverage["gate"]["verdict"])
        self.assertEqual("coverage-completeness", results[-1]["command"][0])

    def test_stale_source_is_consistent_across_suite_and_gate_coverage(self) -> None:
        coverage = build_coverage(
            "ff1",
            "build-id",
            [
                {"exit_code": 0, "evidence": "commands.log#command-1"},
                {
                    "exit_code": 1,
                    "verdict": "STALE",
                    "evidence": "commands.log#command-2",
                },
            ],
        )

        self.assertEqual("STALE", coverage["suite_verdict"])
        self.assertEqual("STALE", coverage["gate"]["verdict"])

    def test_manifest_hashes_sources_and_excludes_generated_artifacts(self) -> None:
        manifest = build_source_manifest()
        paths = {entry["path"] for entry in manifest}

        self.assertIn("README.md", paths)
        self.assertIn("firmware/main/main.cpp", paths)
        self.assertFalse(any(path.startswith("artifacts/") for path in paths))
        self.assertFalse(any(".xcodeproj/" in path for path in paths))
        self.assertTrue(all(len(entry["sha256"]) == 64 for entry in manifest))


if __name__ == "__main__":
    unittest.main()
