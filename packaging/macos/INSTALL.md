# 安装 Cardputer Bridge

这是 Public Preview。应用和音频驱动使用 ad-hoc 签名，尚未经过 Apple 公证；要求 Apple silicon 和 macOS 15 或更高版本。安装器会先执行精确的 HAL 运行时兼容性检查，不满足条件时停止写入。

## 安装

1. 将 Cardputer Bridge.app 拖入“应用程序”。
2. 第一次启动时按住 Control 点击应用并选择“打开”；如果仍被拦截，到“系统设置 → 隐私与安全性”选择“仍要打开”。
3. 按住 Control 点击 install-audio-plugin.command，选择“打开”，按提示输入 INSTALL 并进行管理员认证。
4. 打开应用，通过 USB 连接 Cardputer-ADV，按应用引导安装固件和完成配对。

安装器会将已有音频驱动备份到 /Library/Application Support/Cardputer Bridge/Backups/Audio，然后原子替换系统驱动。卸载时运行 uninstall-audio-plugin.command 并输入 UNINSTALL；若升级后需要回退，运行 restore-audio-plugin.command 并输入 RESTORE，它会恢复最近一次旧版备份。

## 校验下载

在下载目录运行：

    shasum -a 256 -c Cardputer-Bridge-v@VERSION@-macOS-arm64.sha256

仅从项目的 GitHub Releases 页面下载，并确认摘要校验通过。macOS 应用使用 ad-hoc 签名不等同于 Developer ID 签名或 Apple 公证；固件的加密签名校验是独立安全边界。
