#!/usr/bin/env bash
set -euo pipefail

destination="/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver"
removed_root="/Library/Application Support/Cardputer Bridge/Backups/Audio/Removed"

printf 'Cardputer Bridge 将移除：%s\n' "$destination"
printf '此操作需要管理员权限，并会重载 Core Audio；正在使用麦克风的 App 可能暂时中断。\n'
printf '输入 UNINSTALL 继续：'
read -r confirmation
[[ "$confirmation" == "UNINSTALL" ]] || { printf '已取消。\n'; exit 1; }

[[ ! -L "$destination" ]] || { printf '拒绝移动符号链接目标。\n' >&2; exit 1; }
if [[ ! -e "$destination" ]]; then
  printf '驱动尚未安装。\n'
  exit 0
fi

removed="$removed_root/CardputerBridgeAudio.driver.$(date -u '+%Y%m%dT%H%M%SZ')"
sudo -v
sudo mkdir -p "$removed_root"
sudo mv "$destination" "$removed"
sudo rm -f /tmp/io.nexu.cardputerbridge.audio-v1.sock /tmp/io.nexu.cardputerbridge.audio-v1.sock.lock
sudo killall coreaudiod 2>/dev/null || true
printf '驱动已移到可恢复备份：%s\n' "$removed"
