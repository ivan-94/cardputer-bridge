#!/usr/bin/env python3
from pathlib import Path
import json
import sys


FORBIDDEN_PRODUCT_COPY = (
    "重新运行首次设置",
    "重新运行首次测试",
    "包 · 缺口",
    "v\\(deviceVersion) 已同步",
    '"首次设置", systemImage: "circle.fill"',
    "默认静音；控制链路失联会立即停止上传声音。",
    "Bluetooth LE HID",
    "约 60 ms 缓冲",
    "以 Mac 设置为准",
    "GATT 控制",
    "音频会话",
    "已有 bond",
    "Wi-Fi 承载实时音频",
    "Core Audio 已枚举",
    "旧版或未识别",
    "BLE HID 键盘",
    "BLE 键盘",
    "正在检查协议",
    "建立安全控制通道",
    "以 Mac 配置覆盖设备",
    'default: fault',
    'fault = error.localizedDescription',
    '"无法扫描 Wi-Fi：\\(error.localizedDescription)"',
)


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: verify_product_ui_policy.py <CardputerBridgeApp.swift> "
            "<BLEBridgeController.swift> <macos-dir>",
            file=sys.stderr,
        )
        return 2

    app_source = Path(sys.argv[1]).read_text()
    ble_source = Path(sys.argv[2]).read_text()
    macos_dir = Path(sys.argv[3])
    project = (macos_dir / "project.yml").read_text()
    wifi_source = (
        macos_dir / "Sources/CardputerBridgeApp/NearbyWiFiController.swift"
    ).read_text()
    firmware_update_source = (
        macos_dir / "Sources/CardputerBridgeApp/FirmwareUpdateController.swift"
    ).read_text()
    product_source = "\n".join((app_source, wifi_source))
    icon_manifest_path = (
        macos_dir / "Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
    )

    required = {
        "sidebar full-row hit target": ".contentShape(Rectangle())" in app_source,
        "physical Cardputer trigger and Mac shortcut controls":
            "CardputerTriggerRecorderField" in app_source
            and "startShortcutLearning" in ble_source
            and "shortcutLearnEvent" in ble_source
            and "ShortcutKeyCaptureNSView" in app_source,
        "short non-wrapping recorder prompts": '"请按 Cardputer…"' in app_source
        and '"按组合键…"' in app_source
        and ".lineLimit(1)" in app_source,
        "manual shortcut editor avoids global shortcut execution":
            "ShortcutManualEditor" in app_source
            and "手动设置，不触发 macOS 全局快捷键" in app_source
            and "ShortcutRecorderDomain.allKeys" in app_source,
        "global recorder intercepts existing macOS bindings":
            "GlobalShortcutEventTap" in app_source
            and "AXIsProcessTrustedWithOptions" in app_source
            and ".headInsertEventTap" in app_source
            and "options: .defaultTap" in app_source
            and "CGEventType.flagsChanged" in app_source
            and "return shouldSuppress ? nil" in app_source,
        "Mac output supports modifier-only and sided modifiers":
            'name: "无主键"' in app_source
            and 'modifierButton("L⌘", bit: 0x08' in app_source
            and 'modifierButton("R⌘", bit: 0x80' in app_source
            and "usage == 0 && modifiers == 0" in app_source,
        "trigger recorder only learns from physical Cardputer":
            "从 Cardputer 实机录入触发键" in app_source
            and "ShortcutLearnControlMessage" in ble_source
            and "event.token == learnToken" in app_source,
        "new mappings require a token-bound physical capture":
            "AddShortcutMappingButton" in app_source
            and "shortcuts.addMapping(from: event)" in app_source
            and "func addMapping()" not in app_source
            and "firstUnused" not in app_source,
        "current Wi-Fi comes from device state": "bluetooth.currentWiFiSSID" in app_source
        and "currentWiFiSSID" in ble_source
        and 'object["ssid"]' in ble_source,
        "connected Wi-Fi hides credentials": "if !deviceWiFiConnected || isEditingWiFi" in app_source,
        "password is never persisted": "@AppStorage(\"cardputerBridge.lastWiFiPassword\")" not in app_source,
        "perceptual desktop meter": "log10(max(level" in app_source,
        "asset catalog configured": "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon" in project,
        "app icon manifest exists": icon_manifest_path.exists(),
        "launch at login uses system service": "SMAppService.mainApp.register()" in app_source
        and "登录时自动启动" in app_source,
        "menu bar lifecycle": "NSStatusBar.system.statusItem" in app_source
        and "applicationShouldTerminateAfterLastWindowClosed" in app_source
        and "return false" in app_source,
        "menu bar microphone control": "toggleMicrophoneFromStatusItem" in app_source,
        "2.4 GHz Wi-Fi scan": "scanForNetworks" in wifi_source
        and "channel.channelBand == .band2GHz" in wifi_source
        and "WiFiNetworkPicker" in app_source,
        "Wi-Fi scan requests macOS location access":
            "import CoreLocation" in wifi_source
            and "CLLocationManagerDelegate" in wifi_source
            and "requestWhenInUseAuthorization" in wifi_source
            and "locationManagerDidChangeAuthorization" in wifi_source
            and "authorizationStatus" in wifi_source,
        "onboarding and microphone share searchable Wi-Fi picker":
            app_source.count("WiFiNetworkPicker(") == 2
            and 'TextField("搜索 Wi-Fi", text: $searchText)' in app_source
            and 'accessibilityIdentifier("onboarding-wifi-picker")' in app_source
            and 'accessibilityIdentifier("microphone-wifi-picker")' in app_source,
        "onboarding Wi-Fi uses discovery and a selectable menu":
            "onboardingWiFiSetupCard" in app_source
            and "onboarding-wifi-picker" in app_source
            and '"\\(accessibilityPrefix)-wifi-rescan"' in app_source
            and "ForEach(filteredNetworks)" in app_source
            and 'Label("其他网络…", systemImage: "keyboard")' in app_source
            and "setupStep == 3, nearbyWiFi.networks.isEmpty" in app_source,
        "overview foregrounds Wi-Fi as a core channel":
            'overviewStatus("Wi-Fi"' in app_source
            and 'Text("连接 Wi-Fi，启用无线麦克风")' in app_source
            and 'accessibilityIdentifier("overview-connect-wifi")' in app_source
            and 'case .ready: bothSystemInputsReady ? "全部可用" : "部分可用"' in app_source,
        "onboarding Wi-Fi reports progress and failure":
            "WiFiProvisioningPhase" in app_source
            and 'Text("正在连接…")' in app_source
            and 'Text("重试连接")' in app_source
            and "连接超时，请检查 Wi-Fi 密码和信号后重试。" in app_source
            and "wifiProvisioningIsConnecting" in app_source,
        "Wi-Fi scan privacy copy": "INFOPLIST_KEY_NSLocationWhenInUseUsageDescription" in project,
        "shortcut page has no redundant explainer card":
            "Cardputer 是你的辅助快捷键盘" not in app_source,
        "daily microphone page has no redundant registration card":
            '"system-microphone-status"' not in app_source,
        "overview uses real device telemetry and trigger events":
            "bluetooth.deviceTelemetry?.batteryPercent" in app_source
            and "bluetooth.deviceTelemetry?.wifiRSSI" in app_source
            and "bluetooth.lastShortcutEvent" in app_source,
        "overview distinguishes BLE from both system inputs":
            "bothSystemInputsReady" in app_source
            and "systemInputSummary" in app_source
            and "bluetooth.hidConnected" in app_source
            and "systemMicrophonePipelineReady" in app_source
            and "两种系统输入均已连接" not in app_source
            and "已完成系统集成" not in app_source,
        "device-newer conflict has a Mac-authoritative action":
            "使用 Mac 上的设置" in app_source
            and "forceNextVersion(after: deviceVersion)" in app_source,
        "diagnostics export is available":
            "CardputerDiagnosticsReport(" in app_source
            and "导出诊断报告" in app_source
            and "NSSavePanel" in app_source,
        "single application instance":
            "NSRunningApplication.runningApplications" in app_source
            and "existing.activate" in app_source,
        "first-use flow gates USB before firmware and pairing":
            '["USB 连接", "安装固件", "连接 Mac", "接入 Wi-Fi", "系统麦克风", "完成"]'
            in app_source
            and "onboarding-usb-readiness" in app_source
            and "onboarding-usb-continue" in app_source
            and "case .ready:" in app_source
            and "Button(\"继续\") { setupStep = 1 }" in app_source,
        "disconnected devices can restart first-use setup safely":
            'Button("重新设置 Cardputer")' in app_source
            and "beginDeviceRecoverySetup" in app_source
            and "bluetooth.forgetRememberedDevice()" in app_source
            and "firmwareUpdate.resetForOnboarding()" in app_source
            and "setupCompleted = false" in app_source
            and "setupStep = 0" in app_source
            and "func forgetRememberedDevice()" in ble_source
            and "UserDefaults.standard.removeObject(" in ble_source
            and "forKey: Self.rememberedDeviceDefaultsKey" in ble_source
            and "func resetForOnboarding()" in firmware_update_source,
        "USB gate validates a flash-capable Cardputer":
            "USBFlashTargetProbe.validatedTarget" in firmware_update_source
            and "board-info" in firmware_update_source
            and "--chip" in firmware_update_source
            and "esp32s3" in firmware_update_source,
        "firmware install verifies application boot":
            "FirmwareBootEvidence.confirmsRunningFirmware" in firmware_update_source
            and 'Array("status\\n".utf8)' in firmware_update_source
            and '"reboot bootloader\\n"' not in firmware_update_source,
        "page title renders once": app_source.count(
            'Text(title).font(.system(size: 30, weight: .bold))'
        ) == 1,
    }
    if icon_manifest_path.exists():
        manifest = json.loads(icon_manifest_path.read_text())
        filenames = {
            item.get("filename") for item in manifest.get("images", []) if item.get("filename")
        }
        required["all app icon files exist"] = bool(filenames) and all(
            (icon_manifest_path.parent / filename).is_file() for filename in filenames
        )

    failures = [name for name, passed in required.items() if not passed]
    failures.extend(
        f"internal product copy: {copy}"
        for copy in FORBIDDEN_PRODUCT_COPY
        if copy in product_source
    )
    if failures:
        print("FAIL product UI policy: " + ", ".join(failures), file=sys.stderr)
        return 1

    print("PASS product_ui_final_copy_recorders_wifi_and_icon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
