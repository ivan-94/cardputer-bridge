#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
from typing import Any


PROBE = Path.home() / ".local/share/cardputer-bridge/runtime/macos-state.json"
CONFIG = Path.home() / "Library/Application Support/Cardputer Bridge/config.json"
EXPECTED = {"g0": True, "mods": 1, "usage": 20}


def read_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AssertionError(f"expected_object path={path}")
    return value


def wait_for_event(kind: str, *, deadline: float) -> dict[str, Any]:
    last: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        try:
            probe = read_object(PROBE)
            event = probe.get("shortcut_learn_event")
            if isinstance(event, dict):
                last = event
                if event.get("event") == kind:
                    return event
        except (OSError, json.JSONDecodeError, AssertionError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"event_timeout expected={kind} last={last}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    before_hash = sha256(CONFIG)
    before_config = read_object(CONFIG)
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                'display notification "如出现蓝牙权限提示，请点击允许" '
                'with title "Cardputer Bridge 真机验收"',
            ],
            check=False,
        )
        subprocess.run(
            ["./scripts/restart-macos-app.sh"],
            check=True,
            env={
                **dict(__import__("os").environ),
                "CARDPUTER_BRIDGE_START_SHORTCUT_LEARNING": "1",
            },
        )
        waiting = wait_for_event(
            "shortcut_learning",
            deadline=time.monotonic() + 60,
        )
        token = waiting.get("token")
        subprocess.run(
            [
                "osascript",
                "-e",
                'display notification "请在 Cardputer 上按 G0 + Ctrl + Q" '
                'with title "Cardputer Bridge 真机验收"',
            ],
            check=False,
        )
        captured = wait_for_event(
            "shortcut_learned",
            deadline=time.monotonic() + 18,
        )
        if captured.get("token") != token:
            raise AssertionError(
                f"token_mismatch waiting={token} captured={captured.get('token')}"
            )
        actual = {key: captured.get(key) for key in EXPECTED}
        if actual != EXPECTED:
            raise AssertionError(f"chord_mismatch expected={EXPECTED} actual={actual}")
        if sha256(CONFIG) != before_hash or read_object(CONFIG) != before_config:
            raise AssertionError("physical_learning_mutated_canonical_config")
        print(
            json.dumps(
                {
                    "result": "PASS",
                    "source": "physical_cardputer",
                    "event": captured,
                    "config_unchanged": True,
                },
                ensure_ascii=False,
            )
        )
        return 0
    except (AssertionError, OSError, subprocess.CalledProcessError) as error:
        print(
            json.dumps(
                {"result": "FAIL", "error": str(error)},
                ensure_ascii=False,
            ),
            file=sys.stderr,
        )
        return 1
    finally:
        subprocess.run(["./scripts/restart-macos-app.sh"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
