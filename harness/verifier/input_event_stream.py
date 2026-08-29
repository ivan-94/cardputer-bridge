from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path
import sys
from typing import Any, Iterable


@dataclass(frozen=True)
class InputVerificationFailure:
    code: str
    line: int
    actual: dict[str, Any]


def verify_events(events: Iterable[dict[str, Any]]) -> list[InputVerificationFailure]:
    sequence = list(events)
    failures: list[InputVerificationFailure] = []
    active_report = (0, 0)
    g0_active = False
    g0_chord_consumed = False
    reports_by_request: dict[str, list[tuple[int, int]]] = {}
    feedback_by_request: dict[str, list[tuple[int, int]]] = {}
    not_mapped_requests: set[str] = set()
    control_loss_requests: set[str] = set()
    snapshots_by_request: dict[str, dict[str, Any]] = {}

    def fail(code: str, line: int, event: dict[str, Any]) -> None:
        failures.append(InputVerificationFailure(code, line, event))

    for line, event in enumerate(sequence, start=1):
        if (
            type(event.get("v")) is not int
            or event.get("v") != 1
            or type(event.get("event")) is not str
        ):
            fail("input_event_schema_invalid", line, event)
            continue
        event_type = event["event"]
        if event_type == "ready":
            continue
        request_id = event.get("request_id")
        if not isinstance(request_id, str) or not request_id:
            fail("input_event_schema_invalid", line, event)
            continue

        if event_type == "input_action":
            action = event.get("action")
            if action not in {
                "g0_down",
                "g0_up",
                "key_down",
                "key_up",
                "ble_disconnected",
            }:
                fail("input_action_invalid", line, event)
                continue
            if action == "g0_down":
                if g0_active:
                    fail("duplicate_g0_down", line, event)
                g0_active = True
                g0_chord_consumed = False
            elif action == "key_down" and g0_active:
                g0_chord_consumed = True
            elif action == "g0_up":
                if not g0_active:
                    fail("g0_up_without_down", line, event)
                g0_active = False
            elif action == "ble_disconnected":
                g0_active = False
                g0_chord_consumed = False
            continue

        if event_type == "hid_report":
            modifiers = event.get("modifiers")
            usage = event.get("usage")
            if (
                type(modifiers) is not int
                or type(usage) is not int
                or not 0 <= modifiers <= 255
                or not 0 <= usage <= 255
            ):
                fail("hid_report_schema_invalid", line, event)
                continue
            active_report = (modifiers, usage)
            reports_by_request.setdefault(request_id, []).append(active_report)
            continue

        if event_type == "shortcut_feedback":
            modifiers = event.get("modifiers")
            usage = event.get("usage")
            trigger_usage = event.get("trigger_usage")
            if not all(type(value) is int for value in (modifiers, usage, trigger_usage)):
                fail("shortcut_feedback_schema_invalid", line, event)
                continue
            feedback_by_request.setdefault(request_id, []).append((modifiers, usage))
            continue

        if event_type == "not_mapped":
            if type(event.get("trigger_usage")) is not int:
                fail("not_mapped_schema_invalid", line, event)
            not_mapped_requests.add(request_id)
            continue

        if event_type == "domain_action":
            action = event.get("action")
            if action == "toggle_mic_intent" and g0_chord_consumed:
                fail("toggle_after_g0_chord", line, event)
            elif action == "control_link_lost":
                control_loss_requests.add(request_id)
            elif action != "toggle_mic_intent":
                fail("domain_action_invalid", line, event)
            continue

        if event_type == "input_snapshot":
            all_keys_up = event.get("all_keys_up")
            snapshot_g0_active = event.get("g0_active")
            if type(all_keys_up) is not bool or type(snapshot_g0_active) is not bool:
                fail("input_snapshot_schema_invalid", line, event)
                continue
            if all_keys_up != (active_report == (0, 0)):
                fail("snapshot_hid_state_mismatch", line, event)
            if snapshot_g0_active != g0_active:
                fail("snapshot_g0_state_mismatch", line, event)
            snapshots_by_request[request_id] = event
            continue

        if event_type == "error":
            fail("harness_reported_error", line, event)
            continue
        fail("input_event_unknown", line, event)

    for request_id, feedback in feedback_by_request.items():
        reports = reports_by_request.get(request_id, [])
        for report in feedback:
            if report not in reports:
                fail(
                    "shortcut_feedback_without_matching_hid",
                    len(sequence),
                    {"request_id": request_id, "feedback": list(report)},
                )
    for request_id in not_mapped_requests:
        if any(report != (0, 0) for report in reports_by_request.get(request_id, [])):
            fail(
                "unmapped_key_leaked_hid",
                len(sequence),
                {"request_id": request_id},
            )
    for request_id in control_loss_requests:
        snapshot = snapshots_by_request.get(request_id)
        if snapshot is None or snapshot.get("all_keys_up") is not True:
            fail(
                "control_loss_without_all_keys_up",
                len(sequence),
                {"request_id": request_id},
            )
    if active_report != (0, 0):
        fail(
            "hid_not_released",
            len(sequence),
            {"modifiers": active_report[0], "usage": active_report[1]},
        )
    if g0_active:
        fail("g0_not_released", len(sequence), {"g0_active": True})
    return failures


def verify_file(path: Path) -> list[InputVerificationFailure]:
    with path.open(encoding="utf-8") as stream:
        events = [json.loads(line) for line in stream if line.strip()]
    return verify_events(events)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print(
            "usage: python3 -m harness.verifier.input_event_stream <events.ndjson>",
            file=sys.stderr,
        )
        return 2
    failures = verify_file(Path(arguments[0]))
    print(
        json.dumps(
            {
                "result": "fail" if failures else "pass",
                "failures": [asdict(failure) for failure in failures],
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
