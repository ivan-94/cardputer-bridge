from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable


@dataclass(frozen=True)
class MacOSHIDVerificationFailure:
    code: str
    line: int
    actual: dict[str, Any]


def verify_events(
    events: Iterable[dict[str, Any]],
    *,
    expected_keycode: int,
    expected_modifiers: int,
) -> list[MacOSHIDVerificationFailure]:
    failures: list[MacOSHIDVerificationFailure] = []
    is_down = False
    completed_pairs = 0
    sequence = list(events)

    def fail(code: str, line: int, event: dict[str, Any]) -> None:
        failures.append(MacOSHIDVerificationFailure(code, line, event))

    for line, event in enumerate(sequence, start=1):
        if event.get("v") != 1 or event.get("event") != "macos_key":
            fail("macos_key_schema_invalid", line, event)
            continue
        phase = event.get("phase")
        keycode = event.get("keycode")
        modifiers = event.get("modifiers")
        if (
            phase not in {"down", "up"}
            or type(keycode) is not int
            or type(modifiers) is not int
        ):
            fail("macos_key_schema_invalid", line, event)
            continue
        if keycode != expected_keycode:
            fail("macos_keycode_mismatch", line, event)
            continue
        if phase == "down":
            if is_down:
                fail("macos_duplicate_key_down", line, event)
            if modifiers != expected_modifiers:
                fail("macos_modifiers_mismatch", line, event)
            is_down = True
        else:
            if not is_down:
                fail("macos_key_up_without_down", line, event)
            else:
                completed_pairs += 1
            is_down = False

    if is_down:
        fail(
            "macos_key_not_released",
            len(sequence),
            {"keycode": expected_keycode},
        )
    if completed_pairs != 1:
        fail(
            "macos_key_pair_count_mismatch",
            len(sequence),
            {"expected": 1, "actual": completed_pairs},
        )
    return failures
