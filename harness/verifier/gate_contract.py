#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def is_nonempty_string_list(value: object) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, str) and bool(item) for item in value)
    )


def verify(contract: dict[str, Any]) -> dict[str, object]:
    errors: list[str] = []
    if type(contract.get("schema_version")) is not int or contract["schema_version"] != 1:
        errors.append("schema_version_invalid")
    contract_id = contract.get("id")
    if not isinstance(contract_id, str) or re.fullmatch(r"(?:FF|PHASE)-\d+", contract_id) is None:
        errors.append("id_invalid")
    for field in ("requirements", "prerequisites", "drive", "assertions"):
        if not is_nonempty_string_list(contract.get(field)):
            errors.append(f"{field}_missing")
    if not isinstance(contract.get("reset"), str) or not contract["reset"]:
        errors.append("reset_missing")
    if not isinstance(contract.get("red_fixture"), str) or not contract["red_fixture"]:
        errors.append("red_fixture_missing")
    if not is_nonempty_string_list(contract.get("observe")):
        errors.append("observe_missing")
    if contract.get("evidence_level") not in {"E0", "E1", "E2", "E3", "E4", "E5"}:
        errors.append("evidence_level_invalid")
    human_gate = contract.get("human_gate")
    if not isinstance(human_gate, list) or not all(isinstance(item, str) and item for item in human_gate):
        errors.append("human_gate_invalid")
    safety = contract.get("safety")
    if not is_nonempty_string_list(safety):
        errors.append("safety_invalid")
    if contract.get("id") == "FF-1":
        prerequisites = contract.get("prerequisites", [])
        safety = contract.get("safety", [])
        if "system_change_authorized" not in prerequisites or "no_system_change_without_consent" not in safety:
            errors.append("system_change_consent_missing")
        recovery_controls = {"backup_existing_bundle", "idempotent_uninstall"}
        if not isinstance(safety, list) or not recovery_controls.issubset(safety):
            errors.append("recovery_strategy_missing")
    return {"valid": not errors, "errors": errors}


def verify_file(path: Path) -> dict[str, object]:
    with path.open(encoding="utf-8") as stream:
        contract = json.load(stream)
    result = verify(contract)
    red_fixture = contract.get("red_fixture")
    if isinstance(red_fixture, str) and red_fixture:
        fixture_path = Path(red_fixture)
        if not fixture_path.is_absolute():
            fixture_path = PROJECT_ROOT / fixture_path
        if not fixture_path.is_file():
            result["errors"].append("red_fixture_not_found")
            result["valid"] = False
    result["contract"] = str(path)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print("usage: python3 -m harness.verifier.gate_contract <contract.json>", file=sys.stderr)
        return 2
    result = verify_file(Path(arguments[0]))
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
