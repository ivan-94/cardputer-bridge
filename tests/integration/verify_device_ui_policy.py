#!/usr/bin/env python3
from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify_device_ui_policy.py <main.cpp> <device_audio.hpp>", file=sys.stderr)
        return 2
    main_source = Path(sys.argv[1]).read_text()
    audio_header = Path(sys.argv[2]).read_text()
    draw_begin = main_source.index("void draw_screen(")
    draw_end = main_source.index("\n}\n\n}  // namespace", draw_begin)
    draw_source = main_source[draw_begin:draw_end]
    signature_begin = main_source.index("std::uint64_t ui_signature(")
    signature_end = main_source.index("\n}\n\nvoid draw_screen(", signature_begin)
    signature_source = main_source[signature_begin:signature_end]
    required = {
        "offscreen sprite": "M5Canvas" in main_source and "pushSprite" in draw_source,
        "no direct full-screen clear": "M5.Display.fillScreen" not in draw_source,
        "no unconditional 10 Hz redraw": "next_draw_ms = now + 100" not in main_source,
        "real microphone meter": "signal_level" in audio_header,
        "perceptual microphone meter": "std::log10" in draw_source
        and "displayed_level" in draw_source,
        "Raycast device palette": "color565(7, 8, 10)" in draw_source
        and "color565(255, 99, 99)" in draw_source,
        "semantic connectivity icons": "draw_bluetooth_icon" in draw_source
        and "draw_wifi_icon" in draw_source
        and 'canvas.print("B")' not in draw_source
        and 'canvas.print("W")' not in draw_source,
        "real battery level is rendered": "M5.Power.getBatteryLevel()" in main_source
        and "draw_battery_status" in draw_source
        and 'canvas.print("%")' in draw_source,
        "display inactivity policy": "kDisplayDimAfterMs" in main_source
        and "kDisplayOffAfterMs" in main_source
        and "M5.Display.sleep()" in main_source
        and "M5.Display.wakeup()" in main_source
        and "display_power_state != DisplayPowerState::kOff" in main_source,
        "Cardputer ADV LED power is held high outside invalid max PWM":
        "ledc_stop(" in main_source
        and "kBacklightLedcChannel" in main_source
        and "M5.Display.setBrightness(255)" not in main_source,
        "recording LED uses optically calibrated Raycast red":
        "kRecordingLedBrightness = 64" in main_source
        and "kRecordingLedRed = 255" in main_source
        and "kRecordingLedGreen = 60" in main_source
        and "kRecordingLedBlue = 16" in main_source
        and 'kRecordingLedDriveRgb[] = "#FF3C10"' in main_source,
        "shortcut success feedback is brief":
        "kShortcutFeedbackDurationMs = 850" in main_source
        and "uptime_ms() + kShortcutFeedbackDurationMs" in main_source,
        "physical USB can request ROM bootloader":
        "kRebootBootloader" in main_source
        and "RTC_CNTL_FORCE_DOWNLOAD_BOOT" in main_source,
        "UI render uses one audio snapshot per loop":
        "const cardbridge::DeviceAudioStatus& audio" in signature_source
        and "device_audio_status()" not in signature_source
        and "const cardbridge::DeviceAudioStatus& audio" in draw_source
        and "device_audio_status()" not in draw_source,
        "off-screen main loop uses lower polling rate":
        "kIdleLoopIntervalMs" in main_source
        and "kActiveLoopIntervalMs" in main_source
        and "display_power_state == DisplayPowerState::kOff" in main_source,
        "diagnostics expose resource headroom":
        "esp_get_minimum_free_heap_size()" in main_source
        and "heap_caps_get_largest_free_block" in main_source
        and "main_stack_high_water_words" in main_source
        and "audio_stack_high_water_words" in main_source
        and "uxQueueMessagesWaiting" in main_source,
    }
    failures = [name for name, passed in required.items() if not passed]
    if failures:
        print("FAIL device UI policy: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("PASS device_ui_buffered_state_driven_and_metered")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
