#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import os
import subprocess
import sys


def run(
    script: Path,
    current_uid: str,
    coreaudio_uid: str,
    ipc_contract: str = "unix-scm-rights-v1",
    peer_auth: str = "getpeereid-mutual-v1",
) -> subprocess.CompletedProcess[str]:
    environment = os.environ | {
        "CARDPUTER_BRIDGE_TEST_MODE": "1",
        "CARDPUTER_BRIDGE_TEST_CURRENT_UID": current_uid,
        "CARDPUTER_BRIDGE_TEST_COREAUDIO_UID": coreaudio_uid,
        "CARDPUTER_BRIDGE_TEST_IPC_CONTRACT": ipc_contract,
        "CARDPUTER_BRIDGE_TEST_PEER_AUTH": peer_auth,
    }
    return subprocess.run(
        [str(script)],
        capture_output=True,
        text=True,
        check=False,
        env=environment,
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_audio_ipc_boundary.py <boundary-script>", file=sys.stderr)
        return 2
    script = Path(sys.argv[1])
    same_uid = run(script, "501", "501")
    cross_uid_contract = run(script, "501", "202")
    unsafe = run(script, "501", "202", ipc_contract="posix-shm-0600")
    if same_uid.returncode != 0 or "PASS audio_ipc_contract_boundary" not in same_uid.stdout:
        print(same_uid.stdout + same_uid.stderr, file=sys.stderr)
        return 1
    if (
        cross_uid_contract.returncode != 0
        or "designed_cross_uid=true" not in cross_uid_contract.stdout
        or "runtime_cross_uid=NOT_RUN" not in cross_uid_contract.stdout
    ):
        print(cross_uid_contract.stdout + cross_uid_contract.stderr, file=sys.stderr)
        return 1
    if unsafe.returncode != 1 or "FF1_IPC_CONTRACT_UNSAFE" not in unsafe.stderr:
        print(unsafe.stdout + unsafe.stderr, file=sys.stderr)
        return 1
    print("PASS audio_ipc_contract_accepts_mutual_uid_fd_broker_and_marks_runtime_not_run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
