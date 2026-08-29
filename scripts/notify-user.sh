#!/bin/sh
set -eu

title="${1:-Cardputer Bridge 需要你的操作}"
message="${2:-请回到 Codex 查看操作提示。}"

osascript - "$title" "$message" <<'APPLESCRIPT'
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"
end run
APPLESCRIPT
