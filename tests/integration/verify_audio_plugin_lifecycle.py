#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def run(script: str, environment: dict[str, str], *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(PROJECT_ROOT / "scripts" / script), *arguments],
        cwd=PROJECT_ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_audio_plugin_lifecycle.py <built-driver>", file=sys.stderr)
        return 2
    source = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="cardputer-bridge-hal-test.") as temporary:
        root = Path(temporary)
        hal_root = root / "HAL"
        backup_root = root / "backups"
        environment = os.environ.copy()
        environment.update(
            {
                "CARDPUTER_BRIDGE_HAL_ROOT": str(hal_root),
                "CARDPUTER_BRIDGE_BACKUP_ROOT": str(backup_root),
                "CARDPUTER_BRIDGE_TEST_MODE": "1",
            }
        )
        destination = hal_root / "CardputerBridgeAudio.driver"

        escape_root = root / "escape"
        escape_root.mkdir()
        linked_hal_root = root / "linked-HAL"
        linked_hal_root.symlink_to(escape_root, target_is_directory=True)
        linked_environment = environment | {
            "CARDPUTER_BRIDGE_HAL_ROOT": str(linked_hal_root)
        }
        escaped = run(
            "install-audio-plugin.sh",
            linked_environment,
            "--source",
            str(source),
            "--confirm-system-change",
        )
        if escaped.returncode == 0 or (escape_root / destination.name).exists():
            print(
                "test-mode install must reject a symlinked HAL root",
                file=sys.stderr,
            )
            return 1

        denied = run("install-audio-plugin.sh", environment, "--source", str(source))
        if denied.returncode != 2 or destination.exists():
            print(
                "install without confirmation must exit 2 without writing\n"
                + denied.stdout
                + denied.stderr,
                file=sys.stderr,
            )
            return 1

        reload_forbidden = run(
            "install-audio-plugin.sh",
            environment,
            "--source",
            str(source),
            "--reload-coreaudio",
            "--confirm-system-change",
        )
        if reload_forbidden.returncode != 2 or destination.exists():
            print(
                "isolated lifecycle tests must never reload real Core Audio\n"
                + reload_forbidden.stdout
                + reload_forbidden.stderr,
                file=sys.stderr,
            )
            return 1

        shutil.copytree(source, destination)
        (destination / "existing-marker").write_text("preserve me", encoding="utf-8")

        installed = run(
            "install-audio-plugin.sh",
            environment,
            "--source",
            str(source),
            "--confirm-system-change",
        )
        if installed.returncode != 0 or not destination.is_dir():
            print(installed.stdout + installed.stderr, file=sys.stderr)
            return 1
        if not any(backup_root.rglob("existing-marker")):
            print("install must back up a different existing bundle", file=sys.stderr)
            return 1

        repeated = run(
            "install-audio-plugin.sh",
            environment,
            "--source",
            str(source),
            "--confirm-system-change",
        )
        if repeated.returncode != 0 or "ALREADY_INSTALLED" not in repeated.stdout:
            print("repeated install must be idempotent", file=sys.stderr)
            return 1

        (destination / "rollback-marker").write_text("restore me", encoding="utf-8")
        failing_environment = environment | {
            "CARDPUTER_BRIDGE_TEST_FAIL_AFTER_BACKUP": "1"
        }
        rolled_back = run(
            "install-audio-plugin.sh",
            failing_environment,
            "--source",
            str(source),
            "--confirm-system-change",
        )
        if rolled_back.returncode == 0 or not (destination / "rollback-marker").is_file():
            print("failed install must restore the previous bundle", file=sys.stderr)
            return 1

        denied_uninstall = run("uninstall-audio-plugin.sh", environment)
        if denied_uninstall.returncode != 2 or not destination.is_dir():
            print("uninstall without confirmation must preserve destination", file=sys.stderr)
            return 1

        uninstalled = run(
            "uninstall-audio-plugin.sh", environment, "--confirm-system-change"
        )
        if uninstalled.returncode != 0 or destination.exists():
            print(uninstalled.stdout + uninstalled.stderr, file=sys.stderr)
            return 1
        if not any(backup_root.rglob("CardputerBridgeAudio.driver")):
            print("uninstall must move the bundle to a recoverable backup", file=sys.stderr)
            return 1

        shutil.copytree(source, destination)
        removal_source = root / "removal-directive.driver"
        removal_source.mkdir()
        (removal_source / "REMOVE_FROM_HAL").write_text(
            "REMOVE_CARDPUTER_BRIDGE_AUDIO_FROM_HAL_v1", encoding="utf-8"
        )
        quarantined = run(
            "install-audio-plugin.sh",
            environment,
            "--source",
            str(removal_source),
            "--confirm-system-change",
        )
        if (
            quarantined.returncode != 0
            or destination.exists()
            or "QUARANTINED_FROM_HAL" not in quarantined.stdout
        ):
            print(quarantined.stdout + quarantined.stderr, file=sys.stderr)
            return 1

    print(
        "PASS audio_plugin_lifecycle_requires_consent_and_is_recoverable_including_runtime_quarantine"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
