#pragma once

#include "control_protocol.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

#include <esp_err.h>

namespace cardbridge {

struct DeviceAudioStatus {
    bool wifi_connected = false;
    bool session_offered = false;
    bool receiver_ready = false;
    bool capture_enabled = false;
    std::uint16_t signal_level = 0;
    std::int32_t wifi_rssi = 0;
    // IEEE 802.11 SSIDs are at most 32 bytes; keep one extra byte for NUL so
    // the Mac never sees a silently truncated current-network name.
    std::array<char, 33> wifi_ssid{};
    std::uint32_t stream_frames_sent = 0;
    std::uint32_t stream_failures = 0;
    std::int32_t last_stream_error = 0;
    std::uint32_t capture_overruns = 0;
    std::uint32_t microphone_record_failures = 0;
    std::uint32_t capture_ring_drops = 0;
    std::uint32_t capture_ring_high_water = 0;
    std::uint32_t maximum_capture_gap_ms = 0;
    std::uint32_t maximum_transport_gap_ms = 0;
    std::uint32_t wifi_disconnect_count = 0;
    std::int32_t last_wifi_disconnect_reason = 0;
    std::uint32_t idle_wait_total = 0;
    std::uint32_t notification_wake_total = 0;
    std::uint32_t wifi_telemetry_refresh_total = 0;
};

esp_err_t device_audio_start();
bool device_audio_stage_ssid(const std::uint8_t* value, std::size_t length);
bool device_audio_stage_password(const std::uint8_t* value, std::size_t length);
esp_err_t device_audio_commit_wifi();
bool device_audio_apply_offer(const AudioOffer& offer);
bool device_audio_mark_receiver_ready(std::uint64_t session_id);
void device_audio_set_capture_enabled(bool enabled);
DeviceAudioStatus device_audio_status();
std::uint32_t device_audio_stack_high_water_words();

}  // namespace cardbridge
