#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import fcntl
import os
import socket
import subprocess
import sys
import tempfile


def start_server(
    server_path: Path,
    socket_path: Path,
    scenario: str,
    capture_path: Path | None = None,
) -> subprocess.Popen[str]:
    command = [str(server_path), "--socket", str(socket_path), "--scenario", scenario]
    if capture_path is not None:
        command.extend(["--capture", str(capture_path)])
    server = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert server.stdout is not None
    ready = server.stdout.readline().strip()
    if not ready.startswith("READY audio_fd_broker"):
        _, stderr = server.communicate(timeout=2)
        raise RuntimeError(f"broker did not become ready: {ready}\n{stderr}")
    return server


def require_counting_pulse(capture_path: Path) -> None:
    project_dir = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "harness.verifier.pcm_raw",
            "--require-counting-pulse-and-silence",
            str(capture_path),
        ],
        cwd=project_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stdout + result.stderr)


def producer_environment(
    socket_path: Path,
    expected_broker_uid: int | None = None,
) -> dict[str, str]:
    environment = os.environ | {
        "CARDPUTER_BRIDGE_AUDIO_TEST_MODE": "1",
        "CARDPUTER_BRIDGE_AUDIO_BROKER_SOCKET": str(socket_path),
    }
    if expected_broker_uid is not None:
        environment["CARDPUTER_BRIDGE_AUDIO_EXPECTED_BROKER_UID"] = str(
            expected_broker_uid
        )
    return environment


def main() -> int:
    if len(sys.argv) != 5:
        print(
            "usage: verify_audio_fd_broker.py <broker-server> <producer> "
            "<driver-probe> <driver-executable>",
            file=sys.stderr,
        )
        return 2
    server_path = Path(sys.argv[1])
    producer_path = Path(sys.argv[2])
    driver_probe_path = Path(sys.argv[3])
    driver_executable_path = Path(sys.argv[4])
    try:
        with tempfile.TemporaryDirectory(prefix="cb-fd-broker-") as temporary:
            socket_path = Path(temporary) / "audio.sock"
            broker_capture = Path(temporary) / "broker.f32le"
            server = start_server(
                server_path,
                socket_path,
                "consumer-first",
                broker_capture,
            )
            producer = subprocess.run(
                [str(producer_path), "--broker-test-pulse"],
                capture_output=True,
                text=True,
                check=False,
                timeout=7,
                env=producer_environment(socket_path),
            )
            server_stdout, server_stderr = server.communicate(timeout=3)
            if producer.returncode != 0 or server.returncode != 0:
                print(
                    producer.stdout + producer.stderr + server_stdout + server_stderr,
                    file=sys.stderr,
                )
                return 1
            if "OBSERVED audio_test_producer consumed_frames=0" in producer.stdout:
                print("broker consumer did not advance the shared read index", file=sys.stderr)
                return 1
            if "PASS broker_consumer_first_pulse_and_stop" not in server_stdout:
                print(server_stdout + server_stderr, file=sys.stderr)
                return 1
            require_counting_pulse(broker_capture)

            reject_socket = Path(temporary) / "reject.sock"
            reject_server = start_server(server_path, reject_socket, "reject-current-user")
            rejected_producer = subprocess.run(
                [str(producer_path), "--broker-test-pulse"],
                capture_output=True,
                text=True,
                check=False,
                timeout=7,
                env=producer_environment(reject_socket),
            )
            reject_stdout, reject_stderr = reject_server.communicate(timeout=3)
            if rejected_producer.returncode == 0 or reject_server.returncode != 0:
                print(
                    rejected_producer.stdout
                    + rejected_producer.stderr
                    + reject_stdout
                    + reject_stderr,
                    file=sys.stderr,
                )
                return 1
            if "PASS broker_rejects_unauthorized_peer" not in reject_stdout:
                print(reject_stdout + reject_stderr, file=sys.stderr)
                return 1

            impostor_socket = Path(temporary) / "impostor.sock"
            impostor_server = start_server(server_path, impostor_socket, "consumer-first")
            impostor_client = subprocess.run(
                [str(producer_path), "--broker-test-pulse"],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
                env=producer_environment(
                    impostor_socket,
                    expected_broker_uid=os.getuid() + 1,
                ),
            )
            if impostor_server.poll() is None:
                impostor_server.terminate()
            impostor_server.communicate(timeout=2)
            if impostor_client.returncode == 0:
                print("producer accepted a broker with the wrong peer uid", file=sys.stderr)
                return 1

            restart_socket = Path(temporary) / "restart.sock"
            restart_server = start_server(server_path, restart_socket, "crash-restart")
            crashed_producer = subprocess.run(
                [str(producer_path), "--broker-test-crash-pulse"],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
                env=producer_environment(restart_socket),
            )
            restarted_producer = subprocess.run(
                [str(producer_path), "--broker-test-pulse"],
                capture_output=True,
                text=True,
                check=False,
                timeout=7,
                env=producer_environment(restart_socket),
            )
            restart_stdout, restart_stderr = restart_server.communicate(timeout=4)
            if (
                crashed_producer.returncode != 0
                or restarted_producer.returncode != 0
                or restart_server.returncode != 0
            ):
                print(
                    crashed_producer.stdout
                    + crashed_producer.stderr
                    + restarted_producer.stdout
                    + restarted_producer.stderr
                    + restart_stdout
                    + restart_stderr,
                    file=sys.stderr,
                )
                return 1
            if "PASS broker_crash_fails_closed_and_restart_recovers" not in restart_stdout:
                print(restart_stdout + restart_stderr, file=sys.stderr)
                return 1

            hostile_socket = Path(temporary) / "hostile.sock"
            hostile_socket.write_text("do-not-delete", encoding="utf-8")
            hostile_server = subprocess.run(
                [
                    str(server_path),
                    "--socket",
                    str(hostile_socket),
                    "--scenario",
                    "consumer-first",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
            )
            if (
                hostile_server.returncode == 0
                or not hostile_socket.is_file()
                or hostile_socket.read_text(encoding="utf-8") != "do-not-delete"
            ):
                print(hostile_server.stdout + hostile_server.stderr, file=sys.stderr)
                return 1

            active_socket_path = Path(temporary) / "active.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as active_socket:
                active_socket.bind(str(active_socket_path))
                active_socket.listen(1)
                active_server = subprocess.run(
                    [
                        str(server_path),
                        "--socket",
                        str(active_socket_path),
                        "--scenario",
                        "consumer-first",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=2,
                )
                if active_server.returncode == 0 or not active_socket_path.exists():
                    print(active_server.stdout + active_server.stderr, file=sys.stderr)
                    return 1
                active_socket.settimeout(1)
                accepted, _ = active_socket.accept()
                accepted.close()
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(1)
                    probe.connect(str(active_socket_path))

            starting_socket_path = Path(temporary) / "starting.sock"
            starting_lock_path = Path(str(starting_socket_path) + ".lock")
            with starting_lock_path.open("a+b") as starting_lock, socket.socket(
                socket.AF_UNIX,
                socket.SOCK_STREAM,
            ) as starting_socket:
                fcntl.flock(starting_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                starting_socket.bind(str(starting_socket_path))
                starting_server = subprocess.run(
                    [
                        str(server_path),
                        "--socket",
                        str(starting_socket_path),
                        "--scenario",
                        "consumer-first",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=2,
                )
                if starting_server.returncode == 0 or not starting_socket_path.exists():
                    print(starting_server.stdout + starting_server.stderr, file=sys.stderr)
                    return 1

            corrupt_socket = Path(temporary) / "corrupt.sock"
            corrupt_server = subprocess.run(
                [
                    str(server_path),
                    "--socket",
                    str(corrupt_socket),
                    "--scenario",
                    "corrupt-ring",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
            )
            if (
                corrupt_server.returncode != 0
                or "PASS broker_corrupt_ring_fails_silent" not in corrupt_server.stdout
            ):
                print(corrupt_server.stdout + corrupt_server.stderr, file=sys.stderr)
                return 1

            malformed_socket = Path(temporary) / "malformed.sock"
            malformed_server = subprocess.run(
                [
                    str(server_path),
                    "--socket",
                    str(malformed_socket),
                    "--scenario",
                    "malformed-rights",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=8,
            )
            if (
                malformed_server.returncode != 0
                or "PASS broker_malformed_rights_rejected_without_fd_leak"
                not in malformed_server.stdout
            ):
                print(malformed_server.stdout + malformed_server.stderr, file=sys.stderr)
                return 1

            plugin_socket = Path(temporary) / "plugin.sock"
            driver_capture = Path(temporary) / "driver.f32le"
            plugin_environment = producer_environment(plugin_socket)
            driver_probe = subprocess.Popen(
                [
                    str(driver_probe_path),
                    str(driver_executable_path),
                    "broker",
                    str(driver_capture),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=plugin_environment,
            )
            assert driver_probe.stdout is not None
            driver_ready = driver_probe.stdout.readline().strip()
            if not driver_ready.startswith("READY audio_driver_fd_broker"):
                _, driver_stderr = driver_probe.communicate(timeout=2)
                print(f"driver broker not ready: {driver_ready}\n{driver_stderr}", file=sys.stderr)
                return 1
            plugin_producer = subprocess.run(
                [str(producer_path), "--broker-test-pulse"],
                capture_output=True,
                text=True,
                check=False,
                timeout=7,
                env=plugin_environment,
            )
            driver_stdout, driver_stderr = driver_probe.communicate(timeout=3)
            if plugin_producer.returncode != 0 or driver_probe.returncode != 0:
                print(
                    plugin_producer.stdout
                    + plugin_producer.stderr
                    + driver_stdout
                    + driver_stderr,
                    file=sys.stderr,
                )
                return 1
            if "AUDIO_DRIVER_FD_BROKER_PASS" not in driver_stdout:
                print(driver_stdout + driver_stderr, file=sys.stderr)
                return 1
            require_counting_pulse(driver_capture)
        print("PASS audio_fd_broker_full_product_seam")
        return 0
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
