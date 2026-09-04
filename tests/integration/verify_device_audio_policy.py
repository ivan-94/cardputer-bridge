#!/usr/bin/env python3
from pathlib import Path
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_device_audio_policy.py <device_audio.cpp>", file=sys.stderr)
        return 2
    source = Path(sys.argv[1]).read_text(encoding="utf-8")
    commit_begin = source.index("esp_err_t device_audio_commit_wifi()")
    commit_end = source.index("\n}\n\nbool device_audio_apply_offer", commit_begin)
    commit_source = source[commit_begin:commit_end]
    capture_source = source[
        source.index("void audio_capture_task(void*)"):
        source.index("void audio_transport_task(void*)")
    ]
    required = {
        "capture clock matches the 16 kHz wire clock": (
            "kM5UnifiedCaptureRequestRate" not in source
            and len(re.findall(r"M5\.Mic\.record\([\s\S]{0,160}?kSampleRate,", source)) >= 2
        ),
        "double-buffered microphone capture": (
            "sample_buffers" in source
            and "for (auto& capture : sample_buffers)" in source
            and "M5.Mic.isRecording() == sample_buffers.size()" in source
            and "completed_buffer_index" in source
        ),
        "codec stays at M5Unified's clean 0 dB default": (
            "kEs8311AdcPga" not in source
            and "M5.In_I2C.writeRegister8" not in source
        ),
        "wifi power follows realtime audio state": (
            "set_runtime_wifi_power_save(" in source
            and "enabled ? WIFI_PS_NONE : WIFI_PS_MIN_MODEM" in source
            and "s_capture_enabled.exchange" in source
        ),
        "capture is isolated from reliable transport": (
            "s_capture_ring.try_push(frame)" in capture_source
            and "send(" not in capture_source
            and "connect(" not in capture_source
            and "psa_aead_encrypt" not in capture_source
            and '"audio_capture"' in source
            and '"audio_stream"' in source
            and "kMicrophoneTaskPriority = 10" in source
            and "kCaptureTaskPriority = 8" in source
            and "kTransportTaskPriority = 9" in source
            and "microphone_config.task_pinned_core = kCaptureTaskCore" in source
        ),
        "transport is bounded nonblocking redundant UDP": (
            "SOCK_DGRAM" in source
            and "IPPROTO_UDP" in source
            and "O_NONBLOCK" in source
            and "kAudioRedundantDatagramBytes" in source
            and "kCaptureRingFrames = 10" in source
            and "SOCK_STREAM" not in source
        ),
        "real signal level is measured": "s_signal_level.store" in source,
        "inactive audio task blocks until work arrives": (
            "kInactiveAudioWaitMs" in source
            and "wait_for_audio_work();" in source
            and "ulTaskNotifyTake" in source
            and "xTaskNotifyGive" in source
        ),
        "idle efficiency is observable": (
            "s_idle_wait_total" in source
            and "s_notification_wake_total" in source
            and "s_wifi_telemetry_refresh_total" in source
        ),
        "audio task stack headroom is observable": (
            "device_audio_stack_high_water_words" in source
            and "uxTaskGetStackHighWaterMark" in source
        ),
        "wifi telemetry polling is rate limited": (
            "kWifiTelemetryRefreshIntervalMs" in source
            and "s_last_wifi_telemetry_ms.compare_exchange_strong" in source
        ),
        "staged wifi password is erased after commit": (
            "std::fill(s_staged_password.begin(), s_staged_password.end(), 0);" in commit_source
            and "s_staged_password_size = 0;" in commit_source
        ),
    }
    failures = [name for name, passed in required.items() if not passed]
    if failures:
        print("FAIL device audio policy: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("PASS device_audio_clock_locked_split_capture_udp_stream_and_metered")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
