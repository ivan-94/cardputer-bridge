# 安装 Cardputer Bridge

这是 Public Preview。应用和音频驱动使用 ad-hoc 签名，尚未经过 Apple 公证；要求 Apple silicon 和 macOS 15 或更高版本。安装器会先执行精确的 HAL 运行时兼容性检查，不满足条件时停止写入。

## 安装

1. 将 Cardputer Bridge.app 拖入“应用程序”。
2. 从“应用程序”打开。若 macOS 显示“Apple 无法验证 Cardputer Bridge”并提供“移动到废纸篓”，请点击“完成”，不要移动到废纸篓。然后进入“系统设置 → 隐私与安全性”，在安全性提示旁点击“仍要打开”，认证后再次选择“打开”。
3. 在首次设置的“系统麦克风”步骤点击“安装系统麦克风”，完成一次标准管理员认证。App 会安装随包附带、已验证签名的驱动并重载 Core Audio。
4. 通过 USB 连接 Cardputer-ADV，按应用引导安装固件，再完成 BLE 配对和 2.4 GHz Wi-Fi 配置。

手工替换为新的 ad-hoc 版本时，macOS 可能再次要求“仍要打开”。如果这台 Mac 曾安装 v0.10.2，并在允许后仍持续 Dock 跳动，请退出卡住的进程，将新版 App 临时命名为 `Cardputer Bridge v@VERSION@.app` 后再打开；这是 macOS 27 Beta 对旧路径保留的错误策略记录，不会影响已有配置。

ZIP 备用包仍附带 install-audio-plugin.command。如果 App 内安装入口不可用，可按住 Control 点击该脚本，选择“打开”，输入 INSTALL 并进行管理员认证。

安装器会将已有音频驱动备份到 /Library/Application Support/Cardputer Bridge/Backups/Audio，然后原子替换系统驱动。卸载时运行 uninstall-audio-plugin.command 并输入 UNINSTALL；若升级后需要回退，运行 restore-audio-plugin.command 并输入 RESTORE，它会恢复最近一次旧版备份。

## 校验下载

在下载目录运行：

    shasum -a 256 -c Cardputer-Bridge-v@VERSION@-macOS-arm64.sha256

仅从项目的 GitHub Releases 页面下载，并确认摘要校验通过。macOS 应用使用 ad-hoc 签名不等同于 Developer ID 签名或 Apple 公证；固件的加密签名校验是独立安全边界。
