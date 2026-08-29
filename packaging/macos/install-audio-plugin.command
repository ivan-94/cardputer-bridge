#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_driver="$script_dir/Audio/CardputerBridgeAudio.driver"
preflight="$script_dir/check-audio-hal-runtime.sh"
destination="/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver"
backup_root="/Library/Application Support/Cardputer Bridge/Backups/Audio"
staging_root=""
staging=""
backup=""
installed=0

[[ -x "$preflight" ]] || { printf '找不到运行时兼容性检查。\n' >&2; exit 1; }
"$preflight"
printf 'Cardputer Bridge 将写入：%s\n' "$destination"
printf '此操作需要管理员权限，并会重载 Core Audio；正在使用麦克风的 App 可能暂时中断。\n'
printf '输入 INSTALL 继续：'
read -r confirmation
[[ "$confirmation" == "INSTALL" ]] || { printf '已取消。\n'; exit 1; }

[[ -d "$source_driver" ]] || { printf '找不到驱动：%s\n' "$source_driver" >&2; exit 1; }
[[ ! -L "$source_driver" ]] || { printf '拒绝安装符号链接来源。\n' >&2; exit 1; }
[[ ! -L "$destination" ]] || { printf '拒绝替换符号链接目标。\n' >&2; exit 1; }
codesign --verify --deep --strict "$source_driver"

rollback() {
  status=$?
  if [[ $status -ne 0 ]]; then
    if [[ $installed -eq 1 && -n "$backup" && -d "$backup" && ! -e "$destination" ]]; then
      sudo mv "$backup" "$destination" || true
    fi
    if [[ -n "$staging_root" && -d "$staging_root" ]]; then
      failed_root="$backup_root/Failed"
      sudo mkdir -p "$failed_root" || true
      sudo mv "$staging_root" "$failed_root/CardputerBridgeAudio.install.$$.failed" || true
    fi
  fi
  exit "$status"
}
trap rollback EXIT

sudo -v
sudo mkdir -p "/Library/Audio/Plug-Ins/HAL" "$backup_root"
staging_root="$(sudo mktemp -d "/Library/Audio/Plug-Ins/HAL/.CardputerBridgeAudio.install.XXXXXX")"
staging="$staging_root/CardputerBridgeAudio.driver"
sudo ditto "$source_driver" "$staging"
sudo chown -R root:wheel "$staging"
sudo codesign --verify --deep --strict "$staging"

if [[ -e "$destination" ]]; then
  backup="$backup_root/CardputerBridgeAudio.driver.$(date -u '+%Y%m%dT%H%M%SZ')"
  sudo mv "$destination" "$backup"
  installed=1
fi
sudo mv "$staging" "$destination"
sudo rmdir "$staging_root"
installed=0
trap - EXIT
sudo rm -f /tmp/io.nexu.cardputerbridge.audio-v1.sock /tmp/io.nexu.cardputerbridge.audio-v1.sock.lock
sudo killall coreaudiod 2>/dev/null || true
printf '安装完成。请重新打开使用麦克风的应用。\n'
