#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import time
from typing import Any


def verify_readiness(probe: dict[str, Any]) -> dict[str, object]:
    errors: list[str] = []
    if probe.get("transport") != "udp":
        errors.append("udp_transport_missing")
    if probe.get("audio_format") != "pcm16le-v2" or probe.get("audio_encrypted") is not False:
        errors.append("plaintext_v2_format_missing")
    if probe.get("status") not in {"listening", "receiving"}:
        errors.append("receiver_not_ready")
    if probe.get("system_microphone_ready") is not True:
        errors.append("system_microphone_not_ready")
    if probe.get("fault"):
        errors.append("receiver_fault_present")
    port = probe.get("listener_port")
    if not isinstance(port, int) or not 0 < port <= 65535:
        errors.append("listener_endpoint_missing")
    session_id = probe.get("session_id")
    if not isinstance(session_id, str) or len(session_id) != 16:
        errors.append("audio_session_missing")
    return {"valid": not errors, "errors": errors}


def verify(probe: dict[str, Any]) -> dict[str, object]:
    errors: list[str] = []
    accepted = probe.get("accepted_packets")
    missing = probe.get("missing_packets")
    if probe.get("status") != "receiving":
        errors.append("receiver_not_receiving")
    if not isinstance(accepted, int) or accepted < 3:
        errors.append("accepted_packets_missing")
    if probe.get("fault"):
        errors.append("receiver_fault_present")
    duplicates = probe.get("duplicate_or_late_packets")
    if isinstance(accepted, int) and isinstance(missing, int):
        if missing != 0:
            errors.append("stream_sequence_gap")
    else:
        errors.append("packet_metrics_missing")
    if not isinstance(duplicates, int) or duplicates != 0:
        errors.append("stream_duplicate_or_late")
    if probe.get("transport") != "udp":
        errors.append("udp_transport_missing")
    if probe.get("audio_format") != "pcm16le-v2" or probe.get("audio_encrypted") is not False:
        errors.append("plaintext_v2_format_missing")
    port = probe.get("listener_port")
    if not isinstance(port, int) or not 0 < port <= 65535:
        errors.append("listener_endpoint_missing")
    session_id = probe.get("session_id")
    if not isinstance(session_id, str) or len(session_id) != 16:
        errors.append("audio_session_missing")
    return {"valid": not errors, "errors": errors}


def verify_file(path: Path, *, readiness_only: bool = False) -> dict[str, object]:
    probe = json.loads(path.read_text(encoding="utf-8"))
    result = verify_readiness(probe) if readiness_only else verify(probe)
    age_seconds = time.time() - path.stat().st_mtime
    if age_seconds > 5:
        result["valid"] = False
        result["errors"].append("runtime_probe_stale")
    result["age_seconds"] = round(age_seconds, 3)
    result["probe"] = str(path)
    result["observed"] = probe
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    readiness_only = len(arguments) == 2 and arguments[0] == "--ready"
    if len(arguments) != 1 and not readiness_only:
        print(
            "usage: python3 -m harness.verifier.audio_runtime_probe "
            "[--ready] <probe.json>",
            file=sys.stderr,
        )
        return 2
    path = Path(arguments[1] if readiness_only else arguments[0])
    result = verify_file(path, readiness_only=readiness_only)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
