#!/usr/bin/env python3
"""Cross-check the visible system microphone status against runtime truth."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import time


PROBE = Path.home() / ".local/share/cardputer-bridge/runtime/audio-state.json"
FIND_STATUS = r'''
tell application "System Events"
  tell process "Cardputer Bridge"
    set candidates to entire contents of window 1
    repeat with candidate in candidates
      set element to contents of candidate
      try
        set identValue to value of attribute "AXIdentifier" of element
        if identValue is not missing value and (identValue as string) is equal to "system-microphone-status" then
          return value of attribute "AXValue" of element as string
        end if
      end try
    end repeat
    return ""
  end tell
end tell
'''
OPEN_MICROPHONE_PAGE = r'''
tell application "System Events"
  tell process "Cardputer Bridge"
    set candidates to entire contents of window 1
    repeat with candidate in candidates
      set element to contents of candidate
      try
        set identValue to value of attribute "AXIdentifier" of element
        if identValue is not missing value and (identValue as string) is equal to "navigation-microphone" then
          perform action "AXPress" of element
          return "pressed"
        end if
      end try
    end repeat
    error "navigation-microphone not found"
  end tell
end tell
'''


def run_applescript(source: str) -> str:
    return subprocess.check_output(["osascript", "-e", source], text=True).strip()


def main() -> int:
    runtime = json.loads(PROBE.read_text(encoding="utf-8"))
    if runtime.get("system_microphone_ready") is not True:
        print(json.dumps({"result": "FAIL", "error": "runtime_microphone_not_ready"}))
        return 1
    run_applescript('tell application id "io.nexu.cardputerbridge.app" to activate')
    detail = run_applescript(FIND_STATUS)
    if not detail:
        run_applescript(OPEN_MICROPHONE_PAGE)
        time.sleep(0.2)
        detail = run_applescript(FIND_STATUS)
    passed = "Core Audio 已枚举系统输入" in detail
    print(json.dumps({
        "result": "PASS" if passed else "FAIL",
        "runtime_system_microphone_ready": True,
        "visible_status": detail,
    }, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
