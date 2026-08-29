#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(script: Path, product: str, build: str, *, override: bool = False) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "CARDPUTER_BRIDGE_TEST_MODE": "1",
            "CARDPUTER_BRIDGE_TEST_PRODUCT_VERSION": product,
            "CARDPUTER_BRIDGE_TEST_BUILD_VERSION": build,
        }
    )
    if override:
        environment["CARDPUTER_BRIDGE_ALLOW_UNVALIDATED_HAL_RUNTIME"] = "1"
    else:
        environment.pop("CARDPUTER_BRIDGE_ALLOW_UNVALIDATED_HAL_RUNTIME", None)
    return subprocess.run(
        [str(script)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_audio_hal_runtime_policy.py <policy-script>", file=sys.stderr)
        return 2
    script = Path(sys.argv[1])

    supported = run(script, "26.6", "25G88")
    if supported.returncode != 0 or "PASS HAL_RUNTIME_VERSION_POLICY" not in supported.stdout:
        print(supported.stdout + supported.stderr, file=sys.stderr)
        return 1

    blocked = run(script, "27.0", "26A5416b")
    if blocked.returncode != 2 or "BLOCKED FF1_HAL_RUNTIME_UNVALIDATED" not in blocked.stderr:
        print(blocked.stdout + blocked.stderr, file=sys.stderr)
        return 1

    validated = run(script, "27.0", "26A5421a")
    if (
        validated.returncode != 0
        or "PASS HAL_RUNTIME_BUILD_VALIDATED" not in validated.stdout
    ):
        print(validated.stdout + validated.stderr, file=sys.stderr)
        return 1

    overridden = run(script, "27.0", "26A5416b", override=True)
    if overridden.returncode != 0 or "WARNING HAL_RUNTIME_OVERRIDE" not in overridden.stderr:
        print(overridden.stdout + overridden.stderr, file=sys.stderr)
        return 1

    invalid = run(script, "beta", "unknown")
    if invalid.returncode != 1 or "FAIL HAL_RUNTIME_VERSION_INVALID" not in invalid.stderr:
        print(invalid.stdout + invalid.stderr, file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="cardputer-hal-policy.") as temporary:
        fake_sw_vers = Path(temporary) / "sw_vers"
        fake_sw_vers.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == -productVersion ]]; then echo 27.0; else echo 26A5416b; fi\n",
            encoding="utf-8",
        )
        fake_sw_vers.chmod(0o755)
        production_environment = os.environ.copy()
        production_environment.update(
            {
                "PATH": f"{temporary}:{production_environment['PATH']}",
                "CARDPUTER_BRIDGE_TEST_MODE": "0",
                "CARDPUTER_BRIDGE_TEST_PRODUCT_VERSION": "26.6",
                "CARDPUTER_BRIDGE_TEST_BUILD_VERSION": "forged",
            }
        )
        production_environment.pop(
            "CARDPUTER_BRIDGE_ALLOW_UNVALIDATED_HAL_RUNTIME", None
        )
        production = subprocess.run(
            [str(script)],
            env=production_environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        if (
            production.returncode != 2
            or "product_version=27.0" not in production.stderr
            or "build_version=26A5416b" not in production.stderr
        ):
            print(production.stdout + production.stderr, file=sys.stderr)
            return 1

    print(
        "PASS audio_hal_runtime_policy_blocks_unvalidated_macos_and_rejects_test_env_in_production"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
