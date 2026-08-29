#!/usr/bin/env python3
from pathlib import Path
import sys


FORBIDDEN_STALE_COPY = (
    "系统麦克风受当前 macOS Beta 阻塞",
    "系统麦克风尚不可注册",
    "当前 macOS 27 Beta 会让系统 Core Audio HAL 枚举挂起",
    "以开发模式继续",
    "这一步受当前系统 Beta 限制",
    "Cardputer Microphone 暂不注册到系统",
)


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: verify_macos_system_microphone_ui_policy.py "
            "<CardputerBridgeApp.swift> <AudioBridgeProducerBridge.cpp>",
            file=sys.stderr,
        )
        return 2

    source = Path(sys.argv[1]).read_text()
    bridge_source = Path(sys.argv[2]).read_text()
    required = {
        "real bridge readiness": "systemMicrophonePipelineReady" in source,
        "daily microphone page stays focused": '"system-microphone-status"' not in source,
        "onboarding status identifier": '"onboarding-system-microphone-status"' in source,
        "full pipeline readiness gate": "if systemMicrophonePipelineReady" in source
        and 'Button("继续")' in source
        and '"安装系统麦克风"' in source,
        "Core Audio enumeration": "CardputerAudioSystemInputIsPublished" in bridge_source
        and "AudioObjectGetPropertyData" in bridge_source
        and "io.nexu.cardputerbridge.microphone" in bridge_source,
        "completion reports system input": 'onboardingResult("系统麦克风"' in source,
        "device page reports system input": 'capability("系统麦克风"' in source,
    }
    failures = [name for name, passed in required.items() if not passed]
    failures.extend(
        f"stale copy: {copy}" for copy in FORBIDDEN_STALE_COPY if copy in source
    )
    if failures:
        print("FAIL macOS system microphone UI policy: " + ", ".join(failures), file=sys.stderr)
        return 1

    print("PASS macos_system_microphone_ui_uses_runtime_truth")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
