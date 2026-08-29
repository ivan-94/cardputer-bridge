#!/usr/bin/env bash
set -euo pipefail

destination="/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver"
backup_root="/Library/Application Support/Cardputer Bridge/Backups/Audio"
removed_root="$backup_root/Removed"
latest=""

for candidate in "$backup_root"/CardputerBridgeAudio.driver.*; do
  if [[ -d "$candidate" && ! -L "$candidate" ]]; then
    latest="$candidate"
  fi
done
[[ -n "$latest" ]] || { printf '没有可恢复的旧版驱动。\n' >&2; exit 1; }
[[ ! -L "$destination" ]] || { printf '拒绝替换符号链接目标。\n' >&2; exit 1; }

printf '将从备份恢复：%s\n' "$latest"
printf '目标位置：%s\n' "$destination"
printf '此操作需要管理员权限，并会重载 Core Audio。\n'
printf '输入 RESTORE 继续：'
read -r confirmation
[[ "$confirmation" == "RESTORE" ]] || { printf '已取消。\n'; exit 1; }

current_backup=""
restored=0
rollback() {
  status=$?
  if [[ $status -ne 0 && $restored -eq 0 && -n "$current_backup" && -e "$current_backup" && ! -e "$destination" ]]; then
    sudo mv "$current_backup" "$destination" || true
  fi
  exit "$status"
}
trap rollback EXIT

sudo -v
sudo mkdir -p "$removed_root"
if [[ -e "$destination" ]]; then
  current_backup="$removed_root/CardputerBridgeAudio.driver.$(date -u '+%Y%m%dT%H%M%SZ').before-restore"
  sudo mv "$destination" "$current_backup"
fi
sudo mv "$latest" "$destination"
restored=1
trap - EXIT
sudo rm -f /tmp/io.nexu.cardputerbridge.audio-v1.sock /tmp/io.nexu.cardputerbridge.audio-v1.sock.lock
sudo killall coreaudiod 2>/dev/null || true
printf '旧版驱动已恢复。\n'
