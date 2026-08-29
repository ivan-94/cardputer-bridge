from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any
import xml.etree.ElementTree as ET


PROJECT_ROOT = Path(__file__).resolve().parents[2]
USER_HOME = Path.home()
RUNNER_VERSION = 2

SUITES = {
    "host": [
        PROJECT_ROOT / "scripts/env-check.sh",
        PROJECT_ROOT / "scripts/verify-contracts.sh",
        PROJECT_ROOT / "scripts/verify-host.sh",
    ],
    "ff0": [
        PROJECT_ROOT / "scripts/env-check.sh",
        PROJECT_ROOT / "scripts/verify-contracts.sh",
        PROJECT_ROOT / "scripts/verify-host.sh",
        PROJECT_ROOT / "scripts/verify-firmware.sh",
        PROJECT_ROOT / "scripts/verify-macos.sh",
        PROJECT_ROOT / "scripts/verify-audio-plugin.sh",
    ],
    "ff1-preflight": [
        PROJECT_ROOT / "scripts/env-check.sh",
        PROJECT_ROOT / "scripts/verify-ff-1-preflight.sh",
    ],
    "ff1": [
        PROJECT_ROOT / "scripts/env-check.sh",
        PROJECT_ROOT / "scripts/verify-ff-1.sh",
    ],
    "ff2-preflight": [
        PROJECT_ROOT / "scripts/env-check.sh",
        PROJECT_ROOT / "scripts/verify-ff-2-preflight.sh",
    ],
    "ff2": [
        PROJECT_ROOT / "scripts/env-check.sh",
        PROJECT_ROOT / "scripts/verify-ff-2.sh",
    ],
}

EVIDENCE_LEVELS = {
    "host": "E2",
    "ff0": "E0-E2",
    "ff1-preflight": "E0-E2",
    "ff1": "E3",
    "ff2-preflight": "E0-E2",
    "ff2": "E4",
}

BOUNDARIES = {
    "host": "Host/fake verification does not prove Cardputer HIL or system microphone behavior.",
    "ff0": "FF-0 proves repeatable builds and local factory loading only; it does not prove HAL installation, a published virtual microphone, Cardputer runtime, BLE, Wi-Fi, or audio quality.",
    "ff1-preflight": "FF-1 Stage B preflight validates the input-device contract plus a Driver-owned anonymous buffer delivered through SCM_RIGHTS with mutual getpeereid UID contracts. It covers consumer-first, peer rejection, producer crash/restart, socket/fd/ring corruption defenses, independent PCM oracles and a recoverable installer in same-UID seams. Real cross-UID runtime is NOT_RUN. It performs no HAL write or audio-service restart, so the coreaudiod sandbox and registration path remain E3.",
    "ff1": "FF-1 requires a published Cardputer Microphone plus independent PCM, silence, reload, and soak evidence. Missing authorization or device publication is BLOCKED, never PASS.",
    "ff2-preflight": "FF-2 host preflight proves deterministic Input Router semantics and an independent HID event oracle only. It does not prove Cardputer keys, BLE HOGP, bonding, GATT encryption, macOS input, or radio reconnection.",
    "ff2": "FF-2 requires Cardputer E4 evidence from a macOS HID consumer, Swift GATT probe, and correlated device events. Host reports and a connected serial port cannot make this gate PASS.",
}


def verdict_for_exit_code(exit_code: int) -> str:
    return {
        0: "PASS",
        1: "FAIL",
        2: "BLOCKED",
        3: "HUMAN_GATE",
    }.get(exit_code, "FAIL")


def run(
    command: list[str],
    extra_environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    if extra_environment is not None:
        environment.update(extra_environment)
    return subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=environment,
    )


def git_value(*arguments: str) -> str:
    completed = run(["git", *arguments])
    return completed.stdout.strip() if completed.returncode == 0 else "unknown"


def command_value(command: list[str], environment: dict[str, str] | None = None) -> str:
    completed = run(command, environment)
    if completed.returncode != 0:
        return f"unavailable(exit={completed.returncode})"
    return completed.stdout.strip()


def write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def build_source_manifest() -> list[dict[str, Any]]:
    excluded_parts = {"artifacts", "managed_components", "__pycache__"}
    entries: list[dict[str, Any]] = []
    for path in sorted(PROJECT_ROOT.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(PROJECT_ROOT)
        if excluded_parts.intersection(relative.parts):
            continue
        if any(part.endswith(".xcodeproj") for part in relative.parts):
            continue
        if relative.as_posix() == "firmware/sdkconfig" or path.suffix == ".pyc":
            continue
        contents = path.read_bytes()
        entries.append(
            {
                "path": relative.as_posix(),
                "size": len(contents),
                "sha256": hashlib.sha256(contents).hexdigest(),
            }
        )
    return entries


def source_build_id(entries: list[dict[str, Any]]) -> str:
    canonical = json.dumps(entries, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def toolchain_manifest() -> dict[str, str]:
    developer_environment = {
        "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"
    }
    return {
        "xcode": command_value(["xcodebuild", "-version"], developer_environment),
        "swift": command_value(["xcrun", "swift", "--version"], developer_environment),
        "esp_idf": command_value(
            [str(USER_HOME / ".local/bin/idf-cardputer"), "--version"]
        ),
        "cmake": command_value(["cmake", "--version"]).splitlines()[0],
        "xcodegen": command_value(["xcodegen", "--version"]),
        "python": platform.python_version(),
    }


def build_coverage(
    suite: str, build_id: str, results: list[dict[str, Any]]
) -> dict[str, Any]:
    source_stale = any(result.get("verdict") == "STALE" for result in results)
    preflight = [
        {
            "id": f"{suite}:command-{index}",
            "verdict": result.get(
                "verdict", verdict_for_exit_code(result["exit_code"])
            ),
            "evidence": result["evidence"],
        }
        for index, result in enumerate(results, start=1)
    ]
    if suite in {"ff1", "ff1-preflight", "ff2", "ff2-preflight"}:
        gate_id = "ff1" if suite.startswith("ff1") else "ff2"
        contract_path = PROJECT_ROOT / f"harness/contracts/{gate_id.replace('ff', 'ff-')}.json"
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        is_preflight = suite.endswith("-preflight")
        observed_gate_verdict = (
            "STALE"
            if source_stale
            else (
                "NOT_RUN"
                if is_preflight
                else verdict_for_exit_code(results[-1]["exit_code"])
            )
        )
        gate_verdict = (
            "FAIL" if observed_gate_verdict == "PASS" else observed_gate_verdict
        )
        suite_verdict = (
            "STALE"
            if source_stale
            else (
                verdict_for_exit_code(results[-1]["exit_code"])
                if is_preflight
                else gate_verdict
            )
        )
        return {
            "schema_version": 1,
            "suite": suite,
            "build_id": build_id,
            "suite_verdict": suite_verdict,
            "gate": {
                "id": contract["id"],
                "verdict": gate_verdict,
                "reason": (
                    "source files changed while the suite was running"
                    if source_stale
                    else (
                        "preflight does not install or exercise the system virtual microphone"
                        if is_preflight
                        else (
                            "coverage evidence is missing for one or more required assertions"
                            if observed_gate_verdict == "PASS"
                            else "required system behavior did not reach PASS"
                        )
                    )
                ),
            },
            "requirements": [
                {
                    "id": requirement,
                    "verdict": "NOT_RUN",
                    "assertions": contract["assertions"],
                    "evidence": None,
                }
                for requirement in contract["requirements"]
            ],
            "preflight": preflight,
        }
    suite_verdict = (
        "STALE"
        if source_stale
        else (
            "PASS"
            if all(result["exit_code"] == 0 for result in results)
            else verdict_for_exit_code(results[-1]["exit_code"])
        )
    )
    return {
        "schema_version": 1,
        "suite": suite,
        "build_id": build_id,
        "suite_verdict": suite_verdict,
        "gate": {
            "id": suite.upper(),
            "verdict": suite_verdict,
        },
        "requirements": [],
        "preflight": preflight,
    }


def reconcile_suite_coverage(
    suite: str,
    build_id: str,
    results: list[dict[str, Any]],
    overall_status: int,
    source_stale: bool,
) -> tuple[list[dict[str, Any]], int, dict[str, Any]]:
    reconciled_results = list(results)
    coverage = build_coverage(suite, build_id, reconciled_results)
    if (
        suite in {"ff1", "ff2"}
        and not source_stale
        and overall_status == 0
        and coverage["gate"]["verdict"] != "PASS"
    ):
        reconciled_results.append(
            {
                "command": ["coverage-completeness"],
                "expected": {"gate_verdict": "PASS"},
                "actual": {"gate_verdict": coverage["gate"]["verdict"]},
                "exit_code": 1,
                "verdict": "FAIL",
                "duration_ms": 0,
                "evidence": f"commands.log#command-{len(reconciled_results) + 1}",
            }
        )
        overall_status = 1
        coverage = build_coverage(suite, build_id, reconciled_results)
    return reconciled_results, overall_status, coverage


def write_junit(path: Path, suite: str, results: list[dict[str, Any]]) -> None:
    failures = sum(result["exit_code"] not in {0, 2, 3} for result in results)
    errors = sum(result["exit_code"] in {2, 3} for result in results)
    total_seconds = sum(result["duration_ms"] for result in results) / 1000
    root = ET.Element(
        "testsuite",
        name=suite,
        tests=str(len(results)),
        failures=str(failures),
        errors=str(errors),
        time=f"{total_seconds:.3f}",
    )
    for index, result in enumerate(results, start=1):
        case = ET.SubElement(
            root,
            "testcase",
            classname=f"cardputer_bridge.{suite}",
            name=Path(result["command"][0]).name,
            time=f"{result['duration_ms'] / 1000:.3f}",
        )
        if result["exit_code"] in {2, 3}:
            error = ET.SubElement(
                case,
                "error",
                message=verdict_for_exit_code(result["exit_code"]),
            )
            error.text = f"See commands.log#command-{index}"
        elif result["exit_code"] != 0:
            failure = ET.SubElement(
                case,
                "failure",
                message=f"expected exit 0, got {result['exit_code']}",
            )
            failure.text = f"See commands.log#command-{index}"
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1 or arguments[0] not in SUITES:
        print(
            "usage: run_suite.py host|ff0|ff1-preflight|ff1|ff2-preflight|ff2",
            file=sys.stderr,
        )
        return 2

    suite = arguments[0]
    started = datetime.now(timezone.utc)
    run_id = started.strftime("%Y%m%dT%H%M%S.%fZ") + f"-{suite}"
    artifact_dir = PROJECT_ROOT / "artifacts/verification" / run_id
    artifact_dir.mkdir(parents=True, exist_ok=False)

    source_manifest = build_source_manifest()
    build_id = source_build_id(source_manifest)

    manifest = {
        "schema_version": 1,
        "runner_version": RUNNER_VERSION,
        "suite": suite,
        "started_at": started.isoformat(),
        "build_id": build_id,
        "git_sha": git_value("rev-parse", "HEAD"),
        "git_status": git_value("status", "--porcelain=v1"),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "hardware": {
            "host_model": command_value(["sysctl", "-n", "hw.model"]),
            "cardputer_serial_candidates": sorted(
                str(path) for path in Path("/dev").glob("cu.usbmodem*")
            ),
        },
        "toolchains": toolchain_manifest(),
        "evidence_level": EVIDENCE_LEVELS[suite],
        "source_manifest": source_manifest,
    }
    write_json(artifact_dir / "manifest.json", manifest)

    results: list[dict[str, Any]] = []
    command_log: list[str] = []
    overall_status = 0

    for command_path in SUITES[suite]:
        command = [str(command_path)]
        command_started = time.monotonic()
        completed = run(
            command,
            {"CARDPUTER_BRIDGE_EVIDENCE_DIR": str(artifact_dir / "raw")},
        )
        duration_ms = round((time.monotonic() - command_started) * 1000)
        result = {
            "command": command,
            "expected": {"exit_code": 0},
            "actual": {"exit_code": completed.returncode},
            "exit_code": completed.returncode,
            "verdict": verdict_for_exit_code(completed.returncode),
            "duration_ms": duration_ms,
            "evidence": f"commands.log#command-{len(results) + 1}",
        }
        results.append(result)
        command_log.extend(
            [
                f"## command-{len(results)}",
                f"$ {command_path}",
                completed.stdout.rstrip(),
                completed.stderr.rstrip(),
                f"exit={completed.returncode} duration_ms={duration_ms}",
                "",
            ]
        )
        if completed.returncode != 0:
            overall_status = completed.returncode
            break

    suite_commands_completed = len(results)

    final_source_manifest = build_source_manifest()
    final_build_id = source_build_id(final_source_manifest)
    source_stale = final_build_id != build_id
    if source_stale:
        results.append(
            {
                "command": ["source-manifest-stability"],
                "expected": {"build_id": build_id},
                "actual": {"build_id": final_build_id},
                "exit_code": 1,
                "verdict": "STALE",
                "duration_ms": 0,
                "evidence": f"commands.log#command-{len(results) + 1}",
            }
        )
        command_log.extend(
            [
                f"## command-{len(results)}",
                "$ source-manifest-stability",
                f"expected_build_id={build_id}",
                f"actual_build_id={final_build_id}",
                "exit=1 duration_ms=0",
                "",
            ]
        )
        overall_status = 1

    result_count_before_reconciliation = len(results)
    results, overall_status, coverage = reconcile_suite_coverage(
        suite,
        build_id,
        results,
        overall_status,
        source_stale,
    )
    if len(results) > result_count_before_reconciliation:
        synthetic_result = results[-1]
        command_log.extend(
            [
                f"## command-{len(results)}",
                "$ coverage-completeness",
                f"expected_gate_verdict={synthetic_result['expected']['gate_verdict']}",
                f"actual_gate_verdict={synthetic_result['actual']['gate_verdict']}",
                "exit=1 duration_ms=0",
                "",
            ]
        )

    manifest["final_build_id"] = final_build_id
    manifest["source_stable"] = not source_stale
    write_json(artifact_dir / "manifest.json", manifest)

    write_json(artifact_dir / "results.json", results)
    write_json(artifact_dir / "coverage.json", coverage)
    write_json(
        artifact_dir / "metrics.json",
        {
            "schema_version": 1,
            "suite": suite,
            "build_id": build_id,
            "command_count": len(results),
            "total_duration_ms": sum(result["duration_ms"] for result in results),
            "commands": [
                {
                    "name": Path(result["command"][0]).name,
                    "duration_ms": result["duration_ms"],
                    "exit_code": result["exit_code"],
                }
                for result in results
            ],
        },
    )
    write_junit(artifact_dir / "junit.xml", suite, results)
    (artifact_dir / "commands.log").write_text(
        "\n".join(command_log).rstrip() + "\n",
        encoding="utf-8",
    )
    raw_events = artifact_dir / "raw" / "host-events.ndjson"
    if raw_events.is_file():
        shutil.copyfile(raw_events, artifact_dir / "events.ndjson")
    verdict = coverage["suite_verdict"]
    (artifact_dir / "verdict.md").write_text(
        f"# {suite} verification: {verdict}\n\n"
        f"- Evidence level: {EVIDENCE_LEVELS[suite]}\n"
        f"- Artifact: `{artifact_dir}`\n"
        f"- Commands completed: {suite_commands_completed}/{len(SUITES[suite])}\n"
        f"- Boundary: {BOUNDARIES[suite]}\n",
        encoding="utf-8",
    )

    print(f"{verdict} suite={suite} evidence={artifact_dir}")
    return overall_status


if __name__ == "__main__":
    raise SystemExit(main())
