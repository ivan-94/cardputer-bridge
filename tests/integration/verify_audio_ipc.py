#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import os
import select
import subprocess
import sys
import time


def start_ready(producer_path: Path, mode: str, environment: dict[str, str]) -> subprocess.Popen[str]:
    producer = subprocess.Popen(
        [str(producer_path), mode],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    )
    assert producer.stdout is not None
    ready = producer.stdout.readline().strip()
    if not ready.startswith("READY audio_test_producer"):
        _, stderr = producer.communicate(timeout=2)
        raise RuntimeError(f"producer did not become ready: {ready}\n{stderr}")
    return producer


def run_probe(
    probe_path: Path,
    driver_path: Path,
    mode: str,
    environment: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(probe_path), str(driver_path), mode],
        capture_output=True,
        text=True,
        check=False,
        timeout=4,
        env=environment,
    )


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: verify_audio_ipc.py <producer> <driver-probe> <driver-executable>",
            file=sys.stderr,
        )
        return 2
    producer_path, probe_path, driver_path = map(Path, sys.argv[1:])
    environment = os.environ | {
        "CARDPUTER_BRIDGE_AUDIO_TEST_MODE": "1",
        "CARDPUTER_BRIDGE_AUDIO_SHM_NAME": f"/cardputer_bridge_test_{os.getpid()}",
    }
    unsafe_test_mode = subprocess.run(
        [str(producer_path), "--test-pulse"],
        capture_output=True,
        text=True,
        check=False,
        env=os.environ,
    )
    if unsafe_test_mode.returncode == 0:
        print("test pulse must refuse the production IPC namespace", file=sys.stderr)
        return 1
    def cleanup() -> None:
        subprocess.run(
            [str(producer_path), "--cleanup-test-ipc"],
            capture_output=True,
            check=False,
            env=environment,
        )

    try:
        cleanup()
        producer = start_ready(producer_path, "--test-pulse", environment)
        probe = run_probe(probe_path, driver_path, "pulse", environment)
        producer_stdout, producer_stderr = producer.communicate(timeout=7)
        if producer.returncode != 0 or probe.returncode != 0:
            print(producer_stdout + producer_stderr + probe.stdout + probe.stderr, file=sys.stderr)
            return 1

        cleanup()
        crashed = start_ready(producer_path, "--test-crash-pulse", environment)
        crashed.communicate(timeout=2)
        # Production preserves a 1.28-second jitter reservoir through network
        # ingress stalls. Wait beyond its 1.5-second crash-failover lease
        # before asserting that an abandoned producer becomes silent.
        time.sleep(1.7)
        expired = run_probe(probe_path, driver_path, "expired", environment)
        if crashed.returncode != 0 or expired.returncode != 0:
            print(expired.stdout + expired.stderr, file=sys.stderr)
            return 1

        cleanup()
        first = start_ready(producer_path, "--test-pulse", environment)
        restart_probe = subprocess.Popen(
            [str(probe_path), str(driver_path), "restart"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        first_stdout, first_stderr = first.communicate(timeout=7)
        assert restart_probe.stdout is not None
        readable, _, _ = select.select([restart_probe.stdout], [], [], 5)
        if not readable:
            restart_probe.kill()
            _, restart_stderr = restart_probe.communicate(timeout=2)
            print(
                first_stdout
                + first_stderr
                + "restart probe did not request the next producer\n"
                + restart_stderr,
                file=sys.stderr,
            )
            return 1
        restart_ready = restart_probe.stdout.readline().strip()
        if restart_ready != "READY audio_driver_restart_waiting":
            restart_probe.kill()
            _, restart_stderr = restart_probe.communicate(timeout=2)
            print(
                first_stdout
                + first_stderr
                + f"unexpected restart readiness: {restart_ready}\n"
                + restart_stderr,
                file=sys.stderr,
            )
            return 1
        second = start_ready(producer_path, "--test-pulse", environment)
        restart_stdout, restart_stderr = restart_probe.communicate(timeout=10)
        second_stdout, second_stderr = second.communicate(timeout=7)
        if first.returncode != 0 or second.returncode != 0 or restart_probe.returncode != 0:
            print(
                first_stdout
                + first_stderr
                + second_stdout
                + second_stderr
                + restart_stdout
                + restart_stderr,
                file=sys.stderr,
            )
            return 1
        required = {
            "AUDIO_DRIVER_PULSE_AND_TAIL_SILENCE_PASS": probe.stdout,
            "AUDIO_DRIVER_EXPIRED_LEASE_SILENCE_PASS": expired.stdout,
        }
        for marker, output in required.items():
            if marker not in output:
                print(
                    f"probe marker missing: {marker}\nprobe output:\n{output}",
                    file=sys.stderr,
                )
                return 1
        print("PASS audio_ipc_pulse_stop_crash_lease_and_restart")
        return 0
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1
    finally:
        cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
