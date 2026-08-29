#!/usr/bin/env python3
from pathlib import Path
import json
import sys


FORBIDDEN_PRODUCT_COPY = (
    "重新运行首次设置",
    "重新运行首次测试",
    "包 · 缺口",
    "v\\(deviceVersion) 已同步",
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
        and "channel.channelNumber <= 14" in wifi_source
        and "选择附近网络" in app_source,
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
            "以 Mac 配置覆盖设备" in app_source
            and "forceNextVersion(after: deviceVersion)" in app_source,
        "diagnostics export is available":
            "CardputerDiagnosticsReport(" in app_source
            and "导出诊断报告" in app_source
            and "NSSavePanel" in app_source,
        "single application instance":
            "NSRunningApplication.runningApplications" in app_source
            and "existing.activate" in app_source,
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
        if copy in app_source
    )
    if failures:
        print("FAIL product UI policy: " + ", ".join(failures), file=sys.stderr)
        return 1

    print("PASS product_ui_final_copy_recorders_wifi_and_icon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
