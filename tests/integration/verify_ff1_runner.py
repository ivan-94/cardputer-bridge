#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body, encoding="utf-8")
    path.chmod(0o755)


def run_runner(source: Path, *, runtime_blocked: bool) -> tuple[subprocess.CompletedProcess[str], bool]:
    temporary = tempfile.TemporaryDirectory(prefix="cardputer-ff1-runner.")
    root = Path(temporary.name)
    project = root / "project"
    runner = project / "scripts" / "verify-ff-1.sh"
    runner.parent.mkdir(parents=True)
    shutil.copy2(source, runner)
    preflight_marker = root / "preflight-ran"

    if runtime_blocked:
        write_executable(
            project / "scripts" / "check-audio-hal-runtime.sh",
            "echo 'BLOCKED FF1_HAL_RUNTIME_UNVALIDATED fixture' >&2\nexit 2\n",
        )
    else:
        write_executable(
            project / "scripts" / "check-audio-hal-runtime.sh",
            "echo 'PASS HAL_RUNTIME_VERSION_POLICY fixture'\n",
        )
    write_executable(
        project / "scripts" / "verify-ff-1-preflight.sh",
        f"touch '{preflight_marker}'\necho 'FF1_PREFLIGHT_PASS fixture'\n",
    )

    build = root / "build" / "audio-plugin"
    write_executable(
        build / "audio_device_probe",
        "if [[ $1 == --require-input ]]; then\n"
        "  echo '{\"event\":\"required_audio_input\",\"found\":true}'\n"
        "  exit 0\n"
        "fi\n"
        "sleep 0.5\n"
        "echo '{\"event\":\"required_running_audio_input\",\"found\":true,\"running\":true}'\n"
        "exit 0\n",
    )
    consumer = root / "authorized-consumer"
    write_executable(consumer, "sleep 1\necho 'BLOCKED microphone permission not granted' >&2\nexit 3\n")
    write_executable(
        build / "audio_test_producer",
        "echo 'READY audio_test_producer frames=1024'\nsleep 5\n",
    )

    environment = os.environ.copy()
    environment.update(
        {
            "CARDPUTER_BRIDGE_BUILD_ROOT": str(root / "build"),
            "CARDPUTER_BRIDGE_PCM_CONSUMER": str(consumer),
            "CARDPUTER_BRIDGE_EVIDENCE_DIR": str(root / "evidence"),
        }
    )
    completed = subprocess.run(
        [str(runner)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    preflight_ran = preflight_marker.exists()
    temporary.cleanup()
    return completed, preflight_ran


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_ff1_runner.py <verify-ff-1.sh>", file=sys.stderr)
        return 2
    runner = Path(sys.argv[1])

    blocked, blocked_preflight_ran = run_runner(runner, runtime_blocked=True)
    if (
        blocked.returncode != 2
        or "CURRENT_GATE FF1=FAIL" not in blocked.stderr
        or blocked_preflight_ran
    ):
        print(blocked.stdout + blocked.stderr, file=sys.stderr)
        return 1

    permission, permission_preflight_ran = run_runner(runner, runtime_blocked=False)
    if (
        permission.returncode != 3
        or "HUMAN_GATE FF1_MICROPHONE_PERMISSION_REQUIRED" not in permission.stderr
        or not permission_preflight_ran
    ):
        print(permission.stdout + permission.stderr, file=sys.stderr)
        return 1

    print("PASS ff1_runner_preserves_fail_blocked_and_human_gate_semantics")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
