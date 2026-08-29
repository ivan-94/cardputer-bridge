from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path
import sys
from typing import Any, Iterable


@dataclass(frozen=True)
class VerificationFailure:
    code: str
    line: int
    actual: dict[str, Any]


def verify_events(events: Iterable[dict[str, Any]]) -> list[VerificationFailure]:
    failures: list[VerificationFailure] = []
    reported_codes: set[str] = set()

    for line_number, event in enumerate(events, start=1):
        envelope_valid = (
            type(event.get("v")) is int
            and event.get("v") == 1
            and type(event.get("event")) is str
        )
        if not envelope_valid:
            if "event_schema_invalid" not in reported_codes:
                failures.append(
                    VerificationFailure(
                        code="event_schema_invalid",
                        line=line_number,
                        actual=event,
                    )
                )
                reported_codes.add("event_schema_invalid")
            continue
        if event["event"] != "transition":
            continue

        required_types = {
            "v": int,
            "event": str,
            "action": str,
            "source": str,
            "mic_intent": str,
            "capture_gate": str,
            "ble_control_authenticated": bool,
            "wifi_audio_authenticated": bool,
            "virtual_mic_ready": bool,
        }
        schema_valid = all(
            key in event and type(event[key]) is expected_type
            for key, expected_type in required_types.items()
        )
        schema_valid = schema_valid and event["mic_intent"] in {"muted", "live"}
        schema_valid = schema_valid and event["capture_gate"] in {"closed", "open"}
        if not schema_valid:
            if "event_schema_invalid" not in reported_codes:
                failures.append(
                    VerificationFailure(
                        code="event_schema_invalid",
                        line=line_number,
                        actual=event,
                    )
                )
                reported_codes.add("event_schema_invalid")
            continue

        if event["capture_gate"] != "open":
            continue

        invariant_codes = []
        if not event["ble_control_authenticated"]:
            invariant_codes.append("capture_open_without_control")
        if not event["wifi_audio_authenticated"]:
            invariant_codes.append("capture_open_without_wifi")
        if not event["virtual_mic_ready"]:
            invariant_codes.append("capture_open_without_virtual_mic")
        if event["mic_intent"] != "live":
            invariant_codes.append("capture_open_without_live_intent")

        for code in invariant_codes:
            if code in reported_codes:
                continue
            failures.append(
                VerificationFailure(
                    code=code,
                    line=line_number,
                    actual=event,
                )
            )
            reported_codes.add(code)

    return failures


def verify_file(path: Path) -> list[VerificationFailure]:
    with path.open(encoding="utf-8") as stream:
        events = [json.loads(line) for line in stream if line.strip()]
    return verify_events(events)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print("usage: python3 -m harness.verifier.event_stream <events.ndjson>", file=sys.stderr)
        return 2

    path = Path(arguments[0])
    failures = verify_file(path)
    result = {
        "result": "fail" if failures else "pass",
        "failures": [asdict(failure) for failure in failures],
    }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
