# 安装 Cardputer Bridge

应用和音频驱动使用 ad-hoc 签名，尚未经过 Apple 公证；要求 Apple silicon 和 macOS 15 或更高版本。

## 安装

1. 将 Cardputer Bridge.app 拖入“应用程序”。
2. 从“应用程序”打开。若 macOS 显示“Apple 无法验证 Cardputer Bridge”并提供“移动到废纸篓”，请点击“完成”，不要移动到废纸篓。然后进入“系统设置 → 隐私与安全性”，在安全性提示旁点击“仍要打开”，认证后再次选择“打开”。
3. 在首次设置的“系统麦克风”步骤点击“安装系统麦克风”，完成一次标准管理员认证。
4. 通过 USB 连接 Cardputer-ADV，按应用引导安装固件，再完成蓝牙配对和 2.4 GHz Wi-Fi 配置。

替换为新的 ad-hoc 版本后，macOS 可能再次要求“仍要打开”。这是因为新版本的代码签名摘要已经改变；正式的 Developer ID 签名和 Apple 公证可以消除这一步，但需要加入 Apple Developer Program。

ZIP 备用包仍附带 install-audio-plugin.command。如果 App 内安装入口不可用，可按住 Control 点击该脚本，选择“打开”，输入 INSTALL 并进行管理员认证。

ZIP 备用包内还提供卸载和恢复脚本，供故障排查使用。

## 校验下载

在下载目录运行：

    shasum -a 256 -c Cardputer-Bridge-v@VERSION@-macOS-arm64.sha256

仅从项目的 GitHub Releases 页面下载，并确认摘要校验通过。
