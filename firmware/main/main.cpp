#include "ble_bridge.h"
#include "bridge_domain.hpp"
#include "cardputer_adv_input.hpp"
#include "control_protocol.hpp"
#include "control_lease.hpp"
#include "device_audio.hpp"
#include "device_shortcut_config.hpp"
#include "firmware_update.hpp"
#include "firmware_update_policy.hpp"
#include "input_router.hpp"
#include "recording_led.hpp"
#include "serial_harness_protocol.hpp"

#include <M5Unified.h>
#include <driver/ledc.h>
#include <driver/usb_serial_jtag.h>
#include <esp_err.h>
#include <esp_app_desc.h>
#include <esp_heap_caps.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#include <soc/rtc_cntl_reg.h>
#include <soc/soc.h>

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string_view>

namespace {

constexpr char kBuildId[] = "cardputer-bridge-phase3";

constexpr int kNoRemoteMicIntent = -1;
constexpr int kRemoteMicMuted = 0;
constexpr int kRemoteMicLive = 1;
constexpr std::uint8_t kDisplayActiveBrightness = 96;
constexpr std::uint8_t kDisplayDimBrightness = 20;
// Calibrated against the assembled Cardputer ADV, whose blue LED channel is
// optically much stronger than the CSS preview.  These are device drive
// values; the product design token remains Raycast red (#FF6363).
constexpr std::uint8_t kRecordingLedBrightness = 64;
constexpr std::uint8_t kRecordingLedRed = 255;
constexpr std::uint8_t kRecordingLedGreen = 60;
constexpr std::uint8_t kRecordingLedBlue = 16;
constexpr char kRecordingLedDriveRgb[] = "#FF3C10";
constexpr std::uint64_t kShortcutFeedbackDurationMs = 850;
constexpr std::uint32_t kG0DebounceMs = 30;
constexpr std::uint64_t kDisplayDimAfterMs = 15'000;
constexpr std::uint64_t kDisplayOffAfterMs = 30'000;
constexpr std::uint64_t kBatterySampleIntervalMs = 10'000;
// Keep live feedback responsive without returning to an unbounded full-frame
// redraw. Ten visual updates per second still leave most core-0 time to the
// Wi-Fi/BLE stacks while making the meter track speech within about 100 ms.
constexpr std::uint64_t kLiveWaveformIntervalMs = 100;
constexpr std::uint32_t kActiveLoopIntervalMs = 10;
constexpr std::uint32_t kIdleLoopIntervalMs = 20;
std::atomic_int g_remote_mic_intent_requested{kNoRemoteMicIntent};
std::atomic_uint32_t g_ble_heartbeats_pending{0};
std::atomic_uint32_t g_hid_reports_sent{0};
std::atomic_uint32_t g_hid_report_failures{0};
std::atomic_bool g_input_all_keys_up{true};
std::atomic_int g_battery_level{-1};
std::atomic_bool g_external_power_present{false};
std::atomic_int g_recording_led_target{0};
std::atomic_bool g_recording_led_power_hold{false};

constexpr ledc_mode_t kBacklightLedcMode = LEDC_LOW_SPEED_MODE;
constexpr ledc_channel_t kBacklightLedcChannel = LEDC_CHANNEL_7;

const char* recording_led_target_label() {
    return g_recording_led_target.load(std::memory_order_acquire) == 1
        ? "red"
        : "off";
}

bool external_power_present() {
    const int vbus_mv = M5.Power.getVBUSVoltage();
    if (vbus_mv >= 4000) return true;
    return M5.Power.isCharging() == m5::Power_Class::is_charging;
}

enum class DisplayPowerState : std::uint8_t {
    kActive,
    kDim,
    kOff,
};

std::uint8_t display_brightness_for(DisplayPowerState state) {
    switch (state) {
        case DisplayPowerState::kActive:
            return kDisplayActiveBrightness;
        case DisplayPowerState::kDim:
            return kDisplayDimBrightness;
        case DisplayPowerState::kOff:
            return 0;
    }
    return kDisplayActiveBrightness;
}

void apply_recording_led_effect(
    cardbridge::RecordingLedEffect effect,
    DisplayPowerState display_power_state
) {
    if (effect == cardbridge::RecordingLedEffect::kNoChange) {
        return;
    }
    esp_err_t power_result = ESP_OK;
    if (effect == cardbridge::RecordingLedEffect::kSolidRed) {
        // Cardputer ADV gates the WS2812 supply through GPIO38, shared with
        // LCD backlight PWM channel 7. M5GFX configures this channel with a
        // non-zero offset; brightness 255 therefore calculates a 9-bit duty
        // above the legal maximum instead of producing a stable high level.
        // Stop PWM with idle=high, wait for the LED rail to settle, then send
        // the color frame. A later brightness update restarts PWM.
        power_result = ledc_stop(
            kBacklightLedcMode,
            kBacklightLedcChannel,
            1
        );
        g_recording_led_power_hold.store(
            power_result == ESP_OK,
            std::memory_order_release
        );
        if (power_result != ESP_OK) {
            g_recording_led_target.store(0, std::memory_order_release);
            std::printf(
                "{\"v\":1,\"event\":\"recording_led_fault\","
                "\"operation\":\"hold_power_high\",\"error\":\"%s\"}\n",
                esp_err_to_name(power_result)
            );
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
        // Use the explicit RGB overload. Generic TFT color constants passed
        // through the template overload previously made physical color-order
        // diagnosis ambiguous.
        M5.Led.setBrightness(kRecordingLedBrightness);
        M5.Led.setAllColor(
            kRecordingLedRed,
            kRecordingLedGreen,
            kRecordingLedBlue
        );
        g_recording_led_target.store(1, std::memory_order_release);
    } else {
        // Transmit OFF while GPIO38 is still continuously high, then restore
        // the UI's active/dim/off policy for the shared supply pin.
        M5.Led.setAllColor(
            static_cast<std::uint8_t>(0),
            static_cast<std::uint8_t>(0),
            static_cast<std::uint8_t>(0)
        );
        g_recording_led_target.store(0, std::memory_order_release);
        vTaskDelay(pdMS_TO_TICKS(1));
        M5.Display.setBrightness(display_brightness_for(display_power_state));
        g_recording_led_power_hold.store(false, std::memory_order_release);
    }
    std::printf(
        "{\"v\":1,\"event\":\"recording_led_update\","
        "\"target\":\"%s\",\"driver_enabled\":%s,\"led_count\":%u,"
        "\"brightness\":%u,\"rgb\":\"%s\","
        "\"power_gpio\":38,\"power_hold\":%s,\"power_result\":\"%s\"}\n",
        recording_led_target_label(),
        M5.Led.isEnabled() ? "true" : "false",
        static_cast<unsigned>(M5.Led.getCount()),
        static_cast<unsigned>(kRecordingLedBrightness),
        kRecordingLedDriveRgb,
        g_recording_led_power_hold.load(std::memory_order_acquire)
            ? "true"
            : "false",
        esp_err_to_name(power_result)
    );
}

void apply_display_power_state(
    DisplayPowerState desired,
    DisplayPowerState& current
) {
    if (desired == current) return;
    if (desired == DisplayPowerState::kOff) {
        M5.Display.sleep();
    } else {
        if (current == DisplayPowerState::kOff) {
            M5.Display.wakeup();
        }
        M5.Display.setBrightness(
            desired == DisplayPowerState::kActive
                ? kDisplayActiveBrightness
                : kDisplayDimBrightness
        );
    }
    current = desired;
}

enum class PendingControlKind : std::uint8_t {
    kWifiSSID,
    kWifiPassword,
    kWifiCommit,
    kAudioOffer,
    kAudioReady,
    kConfigPrepare,
    kConfigChunk,
    kConfigCommit,
    kShortcutLearnStart,
    kShortcutLearnCancel,
    kOTAStart,
};

struct PendingControlCommand {
    PendingControlKind kind{PendingControlKind::kWifiCommit};
    std::array<std::uint8_t, 64> value{};
    std::size_t value_size = 0;
    cardbridge::AudioOffer offer{};
    std::uint64_t session_id = 0;
    cardbridge::ConfigPrepare config_prepare{};
    cardbridge::ConfigChunk config_chunk{};
    std::uint32_t learn_token = 0;
    cardbridge::OTAStart ota_start{};
};

QueueHandle_t g_control_command_queue = nullptr;
std::atomic_uint32_t g_control_command_drops{0};
std::atomic_bool g_audio_offer_rejected{false};
std::atomic_bool g_audio_offer_state_dirty{false};

void enqueue_control_command(const PendingControlCommand& command) {
    if (g_control_command_queue == nullptr ||
        xQueueSend(g_control_command_queue, &command, 0) != pdTRUE) {
        g_control_command_drops.fetch_add(1, std::memory_order_relaxed);
    }
}

void on_vendor_command(const std::uint8_t* data, std::size_t length, void*) {
    constexpr std::size_t kMaxControlMessageBytes = 160;
    if (data == nullptr || length == 0 || length > kMaxControlMessageBytes) {
        return;
    }

    const auto request = cardbridge::parse_set_mic_intent(
        std::string_view(reinterpret_cast<const char*>(data), length)
    );
    if (request == cardbridge::RemoteMicIntentRequest::kLive) {
        g_remote_mic_intent_requested.store(
            kRemoteMicLive,
            std::memory_order_release
        );
        return;
    } else if (request == cardbridge::RemoteMicIntentRequest::kMuted) {
        g_remote_mic_intent_requested.store(
            kRemoteMicMuted,
            std::memory_order_release
        );
        return;
    }

    PendingControlCommand command{};
    if (cardbridge::parse_staged_base64_value(
            std::string_view(reinterpret_cast<const char*>(data), length),
            "wifi_stage_ssid",
            command.value.data(),
            32,
            command.value_size)) {
        command.kind = PendingControlKind::kWifiSSID;
        enqueue_control_command(command);
        return;
    }
    if (cardbridge::parse_staged_base64_value(
            std::string_view(reinterpret_cast<const char*>(data), length),
            "wifi_stage_password",
            command.value.data(),
            command.value.size(),
            command.value_size)) {
        command.kind = PendingControlKind::kWifiPassword;
        enqueue_control_command(command);
        return;
    }
    const std::string_view message(
        reinterpret_cast<const char*>(data),
        length
    );
    if (cardbridge::is_wifi_commit(message)) {
        command.kind = PendingControlKind::kWifiCommit;
        enqueue_control_command(command);
        return;
    }
    if (cardbridge::parse_audio_offer(message, command.offer)) {
        g_audio_offer_rejected.store(false, std::memory_order_release);
        command.kind = PendingControlKind::kAudioOffer;
        enqueue_control_command(command);
        return;
    }
    if (message.find("\"type\":\"audio_offer\"") != std::string_view::npos) {
        g_audio_offer_rejected.store(true, std::memory_order_release);
        g_audio_offer_state_dirty.store(true, std::memory_order_release);
    }
    if (cardbridge::parse_audio_ready(message, command.session_id)) {
        command.kind = PendingControlKind::kAudioReady;
        enqueue_control_command(command);
        return;
    }
    if (cardbridge::parse_config_prepare(message, command.config_prepare)) {
        command.kind = PendingControlKind::kConfigPrepare;
        enqueue_control_command(command);
        return;
    }
    if (cardbridge::parse_config_chunk(message, command.config_chunk)) {
        command.kind = PendingControlKind::kConfigChunk;
        enqueue_control_command(command);
        return;
    }
    if (cardbridge::is_config_commit(message)) {
        command.kind = PendingControlKind::kConfigCommit;
        enqueue_control_command(command);
        return;
    }
    cardbridge::ShortcutLearnRequest learn_request{};
    if (cardbridge::parse_shortcut_learn_request(message, learn_request)) {
        command.learn_token = learn_request.token;
        command.kind = learn_request.kind ==
                cardbridge::ShortcutLearnRequestKind::kStart
            ? PendingControlKind::kShortcutLearnStart
            : PendingControlKind::kShortcutLearnCancel;
        enqueue_control_command(command);
        return;
    }
    if (cardbridge::parse_ota_start(message, command.ota_start)) {
        command.kind = PendingControlKind::kOTAStart;
        enqueue_control_command(command);
    }
}

void on_vendor_heartbeat(const std::uint8_t* data, std::size_t length, void*) {
    constexpr std::size_t kMaxControlMessageBytes = 160;
    if (data == nullptr || length == 0 || length > kMaxControlMessageBytes) {
        return;
    }
    if (cardbridge::is_heartbeat(
            std::string_view(reinterpret_cast<const char*>(data), length))) {
        g_ble_heartbeats_pending.fetch_add(1, std::memory_order_release);
    }
}

std::uint64_t uptime_ms() {
    return static_cast<std::uint64_t>(esp_timer_get_time() / 1000);
}

const char* board_name(m5::board_t board) {
    switch (board) {
        case m5::board_t::board_M5CardputerADV:
            return "CardputerADV";
        case m5::board_t::board_M5Cardputer:
            return "Cardputer";
        default:
            return "unsupported";
    }
}

const char* mic_label(const cardbridge::BridgeState& state) {
    return state.mic_intent == cardbridge::MicIntent::kLive
        ? "MIC LIVE"
        : "MIC MUTED";
}

void publish_state(const cardbridge::BridgeState& state) {
    const auto audio = cardbridge::device_audio_status();
    char state_json[192]{};
    std::snprintf(
        state_json,
        sizeof(state_json),
        "{\"v\":1,\"mic_intent\":\"%s\",\"capture_gate\":\"%s\",\"hid\":\"%s\","
        "\"wifi\":\"%s\",\"ssid\":\"%s\",\"audio\":\"%s\",\"of\":%u,"
        "\"cfg_v\":\"%016" PRIx64 "\"}",
        state.mic_intent == cardbridge::MicIntent::kLive ? "live" : "muted",
        state.capture_gate == cardbridge::CaptureGate::kOpen ? "open" : "closed",
        ble_bridge_hid_connected() ? "connected" : "disconnected",
        audio.wifi_connected ? "connected" : "offline",
        audio.wifi_ssid.data(),
        audio.receiver_ready ? "ready" : "waiting",
        static_cast<unsigned>(
            g_audio_offer_rejected.load(std::memory_order_acquire)
                ? 2
                : (audio.session_offered ? 1 : 0)
        ),
        cardbridge::device_shortcut_config_version()
    );
    (void)ble_bridge_notify_state(state_json);
}

void publish_telemetry() {
    const auto audio = cardbridge::device_audio_status();
    char telemetry_json[224]{};
    std::snprintf(
        telemetry_json,
        sizeof(telemetry_json),
        "{\"v\":1,\"event\":\"telemetry\",\"bat\":%d,\"rssi\":%" PRId32
        ",\"ext\":%s,\"sent\":%" PRIu32 ",\"fail\":%" PRIu32
        ",\"serr\":%" PRId32
        ",\"mf\":%" PRIu32 ",\"rd\":%" PRIu32
        ",\"rh\":%" PRIu32 ",\"cg\":%" PRIu32 ",\"tg\":%" PRIu32
        ",\"wd\":%" PRIu32 ",\"wr\":%" PRId32 "}",
        g_battery_level.load(std::memory_order_acquire),
        audio.wifi_rssi,
        g_external_power_present.load(std::memory_order_acquire)
            ? "true"
            : "false",
        audio.stream_frames_sent,
        audio.stream_failures,
        audio.last_stream_error,
        audio.microphone_record_failures,
        audio.capture_ring_drops,
        audio.capture_ring_high_water,
        audio.maximum_capture_gap_ms,
        audio.maximum_transport_gap_ms,
        audio.wifi_disconnect_count,
        audio.last_wifi_disconnect_reason
    );
    (void)ble_bridge_notify_state(telemetry_json);
}

void emit_diagnostic_state(
    const cardbridge::BridgeState& state,
    std::uint64_t now_ms,
    std::uint64_t last_heartbeat_ms,
    std::uint32_t ble_heartbeat_total,
    std::uint32_t serial_heartbeat_total,
    const char* source
) {
    const auto audio = cardbridge::device_audio_status();
    const std::int64_t heartbeat_age_ms = last_heartbeat_ms == 0
        ? -1
        : static_cast<std::int64_t>(now_ms - last_heartbeat_ms);
    std::printf(
        "{\"v\":1,\"event\":\"diagnostic_state\",\"source\":\"%s\","
        "\"mic_intent\":\"%s\",\"capture_gate\":\"%s\","
        "\"control_authenticated\":%s,\"physical_ble_authenticated\":%s,"
        "\"hid_connected\":%s,\"hid_report_total\":%" PRIu32 ","
        "\"hid_report_failures\":%" PRIu32 ","
        "\"input_all_keys_up\":%s,"
        "\"wifi_connected\":%s,\"wifi_rssi\":%" PRId32 ","
        "\"audio_receiver_ready\":%s,\"stream_frames_sent\":%" PRIu32 ","
        "\"stream_failures\":%" PRIu32 ",\"capture_overruns\":%" PRIu32 ","
        "\"audio_idle_wait_total\":%" PRIu32 ","
        "\"audio_notification_wake_total\":%" PRIu32 ","
        "\"wifi_telemetry_refresh_total\":%" PRIu32 ","
        "\"free_heap_bytes\":%u,\"minimum_free_heap_bytes\":%u,"
        "\"largest_free_block_bytes\":%u,"
        "\"main_stack_high_water_words\":%u,"
        "\"audio_stack_high_water_words\":%u,"
        "\"control_queue_depth\":%u,"
        "\"battery_level\":%d,\"external_power\":%s,"
        "\"recording_led_target\":\"%s\","
        "\"recording_led_brightness\":%u,\"recording_led_rgb\":\"%s\","
        "\"recording_led_power_hold\":%s,"
        "\"led_driver_enabled\":%s,"
        "\"led_count\":%u,"
        "\"control_command_drops\":%" PRIu32 ","
        "\"heartbeat_age_ms\":%" PRId64 ",\"ble_heartbeat_total\":%" PRIu32 ","
        "\"serial_heartbeat_total\":%" PRIu32 ","
        "\"config_schema\":%u,\"config_version\":%" PRIu64 "}\n",
        source,
        state.mic_intent == cardbridge::MicIntent::kLive ? "live" : "muted",
        state.capture_gate == cardbridge::CaptureGate::kOpen ? "open" : "closed",
        state.ble_control_authenticated ? "true" : "false",
        ble_bridge_control_authenticated() ? "true" : "false",
        ble_bridge_hid_connected() ? "true" : "false",
        g_hid_reports_sent.load(std::memory_order_acquire),
        g_hid_report_failures.load(std::memory_order_acquire),
        g_input_all_keys_up.load(std::memory_order_acquire) ? "true" : "false",
        audio.wifi_connected ? "true" : "false",
        audio.wifi_rssi,
        audio.receiver_ready ? "true" : "false",
        audio.stream_frames_sent,
        audio.stream_failures,
        audio.capture_overruns,
        audio.idle_wait_total,
        audio.notification_wake_total,
        audio.wifi_telemetry_refresh_total,
        static_cast<unsigned>(esp_get_free_heap_size()),
        static_cast<unsigned>(esp_get_minimum_free_heap_size()),
        static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_8BIT)),
        static_cast<unsigned>(uxTaskGetStackHighWaterMark(nullptr)),
        static_cast<unsigned>(cardbridge::device_audio_stack_high_water_words()),
        static_cast<unsigned>(uxQueueMessagesWaiting(g_control_command_queue)),
        g_battery_level.load(std::memory_order_acquire),
        g_external_power_present.load(std::memory_order_acquire)
            ? "true"
            : "false",
        recording_led_target_label(),
        static_cast<unsigned>(kRecordingLedBrightness),
        kRecordingLedDriveRgb,
        g_recording_led_power_hold.load(std::memory_order_acquire)
            ? "true"
            : "false",
        M5.Led.isEnabled() ? "true" : "false",
        static_cast<unsigned>(M5.Led.getCount()),
        g_control_command_drops.load(std::memory_order_relaxed),
        heartbeat_age_ms,
        ble_heartbeat_total,
        serial_heartbeat_total,
        static_cast<unsigned>(cardbridge::device_shortcut_config_schema_version()),
        cardbridge::device_shortcut_config_version()
    );
}

bool read_serial_command(
    char* line,
    std::size_t capacity,
    std::size_t& length
) {
    char byte = '\0';
    while (usb_serial_jtag_read_bytes(&byte, 1, 0) > 0) {
        if (byte == '\n' || byte == '\r') {
            if (length == 0) {
                continue;
            }
            line[length] = '\0';
            return true;
        }
        if (length + 1 < capacity) {
            line[length++] = byte;
        } else {
            length = 0;
        }
    }
    return false;
}

void apply_input_result(
    const cardbridge::InputResult& result,
    cardbridge::BridgeDomain& domain,
    char* feedback,
    std::size_t feedback_size,
    std::uint64_t& feedback_until_ms
) {
    for (std::size_t index = 0; index < result.count; ++index) {
        const auto& effect = result.effects[index];
        switch (effect.kind) {
            case cardbridge::InputEffectKind::kHidReport:
                g_input_all_keys_up.store(
                    effect.report.modifiers == 0 && effect.report.usage == 0,
                    std::memory_order_release
                );
                if (ble_bridge_send_hid(
                    effect.report.modifiers,
                    effect.report.usage
                ) == ESP_OK) {
                    g_hid_reports_sent.fetch_add(1, std::memory_order_release);
                } else {
                    g_hid_report_failures.fetch_add(1, std::memory_order_release);
                }
                break;
            case cardbridge::InputEffectKind::kToggleMicIntent:
                domain.dispatch(
                    cardbridge::BridgeAction::kToggleMicIntent,
                    cardbridge::ActionSource::kHarness
                );
                publish_state(domain.state());
                std::snprintf(feedback, feedback_size, "G0: %s", mic_label(domain.state()));
                feedback_until_ms = uptime_ms() + 2000;
                break;
            case cardbridge::InputEffectKind::kShortcutFeedback: {
                char event_json[160]{};
                std::snprintf(
                    event_json,
                    sizeof(event_json),
                    "{\"v\":1,\"event\":\"shortcut_triggered\","
                    "\"g0\":%s,\"tmods\":%u,\"tusage\":%u,"
                    "\"omods\":%u,\"ousage\":%u}",
                    effect.trigger_includes_g0 ? "true" : "false",
                    static_cast<unsigned>(effect.trigger_modifiers),
                    static_cast<unsigned>(effect.trigger_usage),
                    static_cast<unsigned>(effect.report.modifiers),
                    static_cast<unsigned>(effect.report.usage)
                );
                (void)ble_bridge_notify_state(event_json);
                std::snprintf(feedback, feedback_size, "Shortcut sent");
                feedback_until_ms = uptime_ms() + kShortcutFeedbackDurationMs;
                break;
            }
            case cardbridge::InputEffectKind::kNotMappedFeedback:
                std::snprintf(feedback, feedback_size, "G0 shortcut not mapped");
                feedback_until_ms = uptime_ms() + 2000;
                break;
            case cardbridge::InputEffectKind::kControlLinkLost:
                domain.dispatch(
                    cardbridge::BridgeAction::kControlLinkLost,
                    cardbridge::ActionSource::kBleControl
                );
                publish_state(domain.state());
                std::snprintf(feedback, feedback_size, "BLE disconnected");
                feedback_until_ms = uptime_ms() + 2500;
                break;
            case cardbridge::InputEffectKind::kShortcutLearned: {
                char event_json[160]{};
                std::snprintf(
                    event_json,
                    sizeof(event_json),
                    "{\"v\":1,\"event\":\"shortcut_learned\",\"token\":%" PRIu32
                    ",\"g0\":%s,\"mods\":%u,\"usage\":%u}",
                    effect.learn_token,
                    effect.trigger_includes_g0 ? "true" : "false",
                    static_cast<unsigned>(effect.trigger_modifiers),
                    static_cast<unsigned>(effect.trigger_usage)
                );
                (void)ble_bridge_notify_state(event_json);
                std::snprintf(feedback, feedback_size, "Shortcut captured");
                feedback_until_ms = uptime_ms() + 2000;
                break;
            }
            case cardbridge::InputEffectKind::kShortcutLearnCancelled: {
                char event_json[112]{};
                std::snprintf(
                    event_json,
                    sizeof(event_json),
                    "{\"v\":1,\"event\":\"shortcut_learn_cancelled\",\"token\":%" PRIu32 "}",
                    effect.learn_token
                );
                (void)ble_bridge_notify_state(event_json);
                std::snprintf(feedback, feedback_size, "Shortcut capture cancelled");
                feedback_until_ms = uptime_ms() + 2000;
                break;
            }
        }
    }
}

bool stop_microphone_for_physical_press(
    bool physical_press_observed,
    bool activation_transaction_active,
    cardbridge::BridgeDomain& domain,
    char* feedback,
    std::size_t feedback_size,
    std::uint64_t& feedback_until_ms
) {
    if (!cardbridge::should_stop_microphone_for_physical_press(
            physical_press_observed,
            domain.state().mic_intent == cardbridge::MicIntent::kLive,
            activation_transaction_active)) {
        return false;
    }
    domain.dispatch(
        cardbridge::BridgeAction::kMuteMicIntent,
        cardbridge::ActionSource::kPhysicalInput
    );
    cardbridge::device_audio_set_capture_enabled(false);
    publish_state(domain.state());
    std::snprintf(feedback, feedback_size, "Microphone muted");
    feedback_until_ms = uptime_ms() + 1200;
    return true;
}

std::uint64_t ui_signature(
    const cardbridge::BridgeState& state,
    const cardbridge::DeviceAudioStatus& audio,
    bool keyboard_ready,
    const char* feedback,
    std::uint64_t feedback_until_ms,
    std::uint64_t now
) {
    const auto pairing = ble_bridge_pairing_prompt();
    std::uint64_t signature = 1469598103934665603ULL;
    const auto mix = [&signature](std::uint64_t value) {
        signature ^= value;
        signature *= 1099511628211ULL;
    };
    mix(static_cast<std::uint64_t>(state.mic_intent));
    mix(static_cast<std::uint64_t>(state.capture_gate));
    mix(keyboard_ready);
    mix(ble_bridge_hid_connected());
    mix(audio.wifi_connected);
    mix(audio.receiver_ready);
    mix(static_cast<std::uint64_t>(
        g_battery_level.load(std::memory_order_acquire) + 1
    ));
    mix(pairing.visible);
    mix(pairing.needs_confirmation);
    mix(pairing.passkey);
    if (now < feedback_until_ms && feedback != nullptr) {
        for (const char* character = feedback; *character != '\0'; ++character) {
            mix(static_cast<std::uint8_t>(*character));
        }
    }
    return signature;
}

void draw_screen(
    M5Canvas& canvas,
    const cardbridge::BridgeState& state,
    const cardbridge::DeviceAudioStatus& audio,
    bool keyboard_ready,
    const char* feedback,
    std::uint64_t feedback_until_ms,
    std::uint8_t wave_phase
) {
    const auto pairing = ble_bridge_pairing_prompt();
    const auto background = canvas.color565(7, 8, 10);
    const auto red = canvas.color565(255, 99, 99);
    const auto green = canvas.color565(95, 201, 146);
    const auto text_secondary = canvas.color565(156, 156, 157);
    const auto surface = canvas.color565(16, 17, 17);
    const auto raised = canvas.color565(27, 28, 30);
    const auto divider = canvas.color565(37, 40, 41);

    const auto draw_bluetooth_icon = [&](std::int32_t x, std::int32_t y, std::uint16_t color) {
        canvas.drawFastVLine(x, y - 5, 11, color);
        canvas.drawLine(x, y - 5, x + 4, y - 1, color);
        canvas.drawLine(x + 4, y - 1, x - 3, y + 4, color);
        canvas.drawLine(x - 3, y - 4, x + 4, y + 1, color);
        canvas.drawLine(x + 4, y + 1, x, y + 5, color);
    };
    const auto draw_wifi_icon = [&](std::int32_t x, std::int32_t y, std::uint16_t color) {
        canvas.drawLine(x - 6, y - 3, x, y - 6, color);
        canvas.drawLine(x, y - 6, x + 6, y - 3, color);
        canvas.drawLine(x - 4, y, x, y - 2, color);
        canvas.drawLine(x, y - 2, x + 4, y, color);
        canvas.fillCircle(x, y + 4, 1, color);
    };
    const auto draw_battery_status = [&](std::int32_t x, std::int32_t y) {
        const auto level = g_battery_level.load(std::memory_order_acquire);
        const auto battery_color = level >= 0 && level <= 15 ? red : text_secondary;
        canvas.fillRoundRect(x, y, 52, 17, 5, raised);
        canvas.drawRect(x + 6, y + 5, 11, 7, battery_color);
        canvas.fillRect(x + 17, y + 7, 2, 3, battery_color);
        if (level >= 0) {
            const auto fill_width = std::clamp(level * 9 / 100, 1, 9);
            canvas.fillRect(x + 7, y + 6, fill_width, 5, battery_color);
        }
        canvas.setTextColor(battery_color, raised);
        canvas.setCursor(x + 23, y + 5);
        if (level < 0) {
            canvas.print("--");
        } else {
            canvas.print(level);
            canvas.print("%");
        }
    };

    canvas.fillSprite(background);
    canvas.setTextColor(TFT_WHITE, background);
    canvas.setTextSize(1);
    canvas.setCursor(8, 8);
    canvas.print("CARDBRIDGE");
    draw_battery_status(118, 3);
    canvas.fillRoundRect(176, 3, 25, 17, 5, raised);
    canvas.fillRoundRect(207, 3, 25, 17, 5, raised);
    draw_bluetooth_icon(
        188,
        11,
        ble_bridge_hid_connected() ? green : text_secondary
    );
    draw_wifi_icon(219, 11, audio.wifi_connected ? green : text_secondary);
    canvas.drawFastHLine(8, 25, 224, divider);

    if (pairing.visible) {
        canvas.setTextColor(text_secondary, background);
        canvas.setCursor(8, 36);
        canvas.print("COMPARE ON MAC");
        canvas.setTextColor(TFT_WHITE, background);
        canvas.setTextSize(3);
        canvas.setCursor(8, 53);
        canvas.printf("%06" PRIu32, pairing.passkey);
        canvas.setTextSize(1);
        canvas.setTextColor(red, background);
        canvas.setCursor(8, 103);
        canvas.print(pairing.needs_confirmation
            ? "G0 confirm  /  ESC cancel"
            : "Enter code on Mac");
        canvas.pushSprite(0, 0);
        return;
    }

    const bool intent_live = state.mic_intent == cardbridge::MicIntent::kLive;
    const bool streaming = intent_live
        && state.capture_gate == cardbridge::CaptureGate::kOpen
        && audio.wifi_connected
        && audio.receiver_ready;
    const bool feedback_visible = uptime_ms() < feedback_until_ms
        && feedback != nullptr
        && feedback[0] != '\0';
    const bool shortcut_feedback = feedback_visible
        && std::strstr(feedback, "Shortcut sent") != nullptr;

    if (shortcut_feedback) {
        canvas.setTextColor(text_secondary, background);
        canvas.setCursor(8, 38);
        canvas.print("SENT TO MAC");
        canvas.setTextColor(TFT_WHITE, background);
        canvas.setTextSize(2);
        canvas.setCursor(8, 58);
        canvas.print("SHORTCUT SENT");
        canvas.setTextSize(1);
        canvas.setTextColor(red, background);
        canvas.setCursor(8, 103);
        canvas.print("Delivered over BLE");
        canvas.pushSprite(0, 0);
        return;
    }

    canvas.setTextColor(text_secondary, background);
    canvas.setCursor(8, 37);
    canvas.print(streaming ? "MICROPHONE" : "READY");
    canvas.setTextColor(TFT_WHITE, background);
    canvas.setTextSize(2);
    canvas.setCursor(8, 53);
    canvas.print(streaming ? "MIC LIVE" : (intent_live ? "MIC PAUSED" : "MIC MUTED"));

    constexpr std::array<std::uint8_t, 12> kWaveShape{{
        4, 10, 17, 8, 21, 13, 25, 15, 9, 19, 11, 5,
    }};
    const float raw_level = std::max(1.0f, static_cast<float>(audio.signal_level));
    const float decibels = 20.0f * std::log10(raw_level / 1000.0f);
    const float perceptual_level = streaming
        ? std::clamp((decibels + 60.0f) / 42.0f, 0.0f, 1.0f)
        : 0.0f;
    static float displayed_level = 0.0f;
    const float smoothing = perceptual_level > displayed_level ? 0.68f : 0.30f;
    displayed_level += (perceptual_level - displayed_level) * smoothing;
    const std::uint32_t visual_level = streaming
        ? static_cast<std::uint32_t>(60.0f + displayed_level * 940.0f)
        : 0;
    for (std::size_t index = 0; index < kWaveShape.size(); ++index) {
        const auto shape = kWaveShape[(index + wave_phase) % kWaveShape.size()];
        const std::int32_t height = streaming
            ? 3 + static_cast<std::int32_t>(shape * visual_level / 1000)
            : 3;
        const std::int32_t x = 174 + static_cast<std::int32_t>(index) * 5;
        canvas.fillRoundRect(x, 68 - height / 2, 3, height, 2,
            streaming ? red : divider);
    }

    canvas.fillRoundRect(8, 92, 224, 28, 6, surface);
    canvas.setTextSize(1);
    if (feedback_visible) {
        canvas.setTextColor(red, surface);
        canvas.setCursor(16, 102);
        canvas.print(feedback);
    } else if (intent_live && !streaming) {
        canvas.setTextColor(red, surface);
        canvas.setCursor(16, 102);
        canvas.print(audio.wifi_connected ? "Waiting for Mac audio" : "Audio offline - mic protected");
    } else {
        canvas.setTextColor(streaming ? red : text_secondary, surface);
        canvas.setCursor(16, 102);
        canvas.print(streaming ? "ANY KEY  mute microphone" : "G0  unmute microphone");
    }
    if (!keyboard_ready) {
        canvas.setTextColor(red, background);
        canvas.setCursor(8, 125);
        canvas.print("KEYBOARD ERROR");
    }
    canvas.pushSprite(0, 0);
}

}  // namespace

extern "C" void app_main() {
    auto config = M5.config();
    config.internal_mic = true;
    config.internal_spk = false;
    M5.begin(config);
    // M5Unified's 10 ms default can be bypassed when a busy loop iteration
    // itself exceeds that interval. Keep the threshold above the normal loop
    // cadence so a raw G0 spike cannot become a second logical press.
    M5.BtnA.setDebounceThresh(kG0DebounceMs);
    M5.Display.setBrightness(kDisplayActiveBrightness);
    g_battery_level.store(
        std::clamp<std::int32_t>(M5.Power.getBatteryLevel(), -1, 100),
        std::memory_order_release
    );
    g_external_power_present.store(
        external_power_present(),
        std::memory_order_release
    );
    M5Canvas screen(&M5.Display);
    screen.setColorDepth(16);
    if (screen.createSprite(M5.Display.width(), M5.Display.height()) == nullptr) {
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setTextColor(TFT_RED, TFT_BLACK);
        M5.Display.setCursor(8, 12);
        M5.Display.print("DISPLAY BUFFER FAILED");
        std::printf(
            "{\"v\":1,\"event\":\"error\","
            "\"code\":\"display_buffer_no_memory\"}\n"
        );
        return;
    }

    usb_serial_jtag_driver_config_t serial_config =
        USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    const esp_err_t serial_result =
        usb_serial_jtag_driver_install(&serial_config);
    if (serial_result != ESP_OK) {
        std::printf(
            "{\"v\":1,\"event\":\"error\","
            "\"code\":\"serial_harness_start_failed\","
            "\"esp_error\":\"%s\"}\n",
            esp_err_to_name(serial_result)
        );
    }

    cardbridge::BridgeDomain domain;
    domain.reset(cardbridge::ResetProfile::kBootUnpaired);
    cardbridge::InputRouter input_router;
    // BLE writes are paced and this queue is drained on every main-loop turn.
    // Keeping forty full command unions reserved over 10 KiB of scarce
    // internal RAM that the microphone/I2S path needs only while recording.
    g_control_command_queue = xQueueCreate(8, sizeof(PendingControlCommand));
    if (g_control_command_queue == nullptr) {
        std::printf(
            "{\"v\":1,\"event\":\"error\","
            "\"code\":\"control_command_queue_no_memory\"}\n"
        );
        return;
    }
    constexpr std::array<cardbridge::ShortcutMapping, 4> kDefaultShortcuts{{
        {true, 0, 0x14, 0x09, 0x14, true},
        {true, 0, 0x06, 0x09, 0x06, true},
        {true, 0, 0x2c, 0x04, 0x2c, true},
        {true, 0, 0x10, 0x0a, 0x10, true},
    }};
    if (!input_router.replace_mappings(
            kDefaultShortcuts.data(),
            kDefaultShortcuts.size())) {
        std::printf(
            "{\"v\":1,\"event\":\"error\","
            "\"code\":\"default_shortcut_invalid\"}\n"
        );
        return;
    }

    const auto board = M5.getBoard();
    cardbridge::CardputerAdvInput keyboard;
    const bool keyboard_ready = board == m5::board_t::board_M5CardputerADV &&
        keyboard.begin();
    char identity_json[160]{};
    std::snprintf(
        identity_json,
        sizeof(identity_json),
        "{\"v\":1,\"device\":\"Cardputer-ADV\",\"service\":\"CardputerBridge\","
        "\"fw\":\"%s\",\"layout\":3,\"ota\":true}",
        esp_app_get_description()->version
    );
    const esp_err_t identity_result = ble_bridge_set_identity(identity_json);
    const esp_err_t ble_result = identity_result == ESP_OK
        ? ble_bridge_start(
        on_vendor_command,
        nullptr,
        on_vendor_heartbeat,
        nullptr
    ) : identity_result;
    if (ble_result != ESP_OK) {
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setTextColor(TFT_RED, TFT_BLACK);
        M5.Display.setTextSize(1);
        M5.Display.setCursor(8, 12);
        M5.Display.printf("BLE START FAILED\n%s", esp_err_to_name(ble_result));
        std::printf(
            "{\"v\":1,\"event\":\"error\",\"code\":\"ble_start_failed\","
            "\"esp_error\":\"%s\"}\n",
            esp_err_to_name(ble_result)
        );
        return;
    }
    const esp_err_t shortcut_config_result =
        cardbridge::device_shortcut_config_start();
    std::array<cardbridge::ShortcutMapping, cardbridge::kMaxShortcutMappings>
        active_shortcuts{};
    const std::size_t active_shortcut_count =
        cardbridge::device_shortcut_config_copy_mappings(
            active_shortcuts.data(),
            active_shortcuts.size()
        );
    const bool active_shortcuts_loaded = input_router.replace_mappings(
        active_shortcuts.data(),
        active_shortcut_count
    );
    if (shortcut_config_result != ESP_OK || !active_shortcuts_loaded) {
        std::printf(
            "{\"v\":1,\"event\":\"error\","
            "\"code\":\"shortcut_config_load_failed\","
            "\"esp_error\":\"%s\"}\n",
            esp_err_to_name(shortcut_config_result)
        );
    }
    const esp_err_t audio_result = cardbridge::device_audio_start();
    if (audio_result != ESP_OK) {
        M5.Display.fillScreen(TFT_BLACK);
        M5.Display.setTextColor(TFT_RED, TFT_BLACK);
        M5.Display.setTextSize(1);
        M5.Display.setCursor(8, 12);
        M5.Display.printf("AUDIO START FAILED\n%s", esp_err_to_name(audio_result));
        std::printf(
            "{\"v\":1,\"event\":\"error\",\"code\":\"audio_start_failed\","
            "\"esp_error\":\"%s\"}\n",
            esp_err_to_name(audio_result)
        );
        return;
    }

    std::printf(
        "{\"v\":1,\"event\":\"ready\",\"build_id\":\"%s\","
        "\"board\":\"%s\",\"harness\":false,\"mic_intent\":\"muted\","
        "\"capture_gate\":\"closed\",\"keyboard_ready\":%s,"
        "\"ble_hid\":\"advertising\",\"vendor_gatt\":\"encrypted_mitm\","
        "\"wifi_audio\":\"waiting_for_config\"}\n",
        kBuildId,
        board_name(board),
        keyboard_ready ? "true" : "false"
    );

    const int stdin_flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    if (stdin_flags >= 0) {
        (void)fcntl(STDIN_FILENO, F_SETFL, stdin_flags | O_NONBLOCK);
    }

    char feedback[64]{};
    std::uint64_t feedback_until_ms = 0;
    std::uint64_t last_ui_signature = ~std::uint64_t{0};
    std::uint64_t next_wave_draw_ms = 0;
    std::uint8_t wave_phase = 0;
    bool pairing_g0_press = false;
    bool activation_g0_press_ignored = false;
    bool g0_press_stopped_microphone = false;
    cardbridge::G0RecordingStopGuard g0_recording_stop_guard;
    bool last_authenticated = false;
    cardbridge::ControlLease control_lease;
    std::array<char, 64> serial_line{};
    std::size_t serial_line_length = 0;
    std::uint32_t ble_heartbeat_total = 0;
    std::uint32_t serial_heartbeat_total = 0;
    std::uint64_t last_heartbeat_ms = 0;
    std::uint64_t next_telemetry_ms = 0;
    bool last_wifi_connected = false;
    bool last_audio_receiver_ready = false;
    std::uint64_t last_local_activity_ms = uptime_ms();
    std::uint64_t next_battery_sample_ms =
        last_local_activity_ms + kBatterySampleIntervalMs;
    DisplayPowerState display_power_state = DisplayPowerState::kActive;
    cardbridge::RecordingLedPolicy recording_led_policy;
    bool led_test_active = false;
    std::uint64_t led_test_until_ms = 0;
    auto last_update_status = cardbridge::firmware_update_status();
    bool running_image_confirmed = false;

    while (true) {
        M5.update();
        const auto now = uptime_ms();
        const auto pairing = ble_bridge_pairing_prompt();
        bool should_wake_display = pairing.visible;

        PendingControlCommand pending_control{};
        while (xQueueReceive(
                   g_control_command_queue,
                   &pending_control,
                   0) == pdTRUE) {
            should_wake_display = true;
            switch (pending_control.kind) {
                case PendingControlKind::kWifiSSID:
                    (void)cardbridge::device_audio_stage_ssid(
                        pending_control.value.data(),
                        pending_control.value_size
                    );
                    break;
                case PendingControlKind::kWifiPassword:
                    (void)cardbridge::device_audio_stage_password(
                        pending_control.value.data(),
                        pending_control.value_size
                    );
                    std::fill(
                        pending_control.value.begin(),
                        pending_control.value.end(),
                        0
                    );
                    break;
                case PendingControlKind::kWifiCommit: {
                    const esp_err_t result = cardbridge::device_audio_commit_wifi();
                    std::snprintf(
                        feedback,
                        sizeof(feedback),
                        "%s",
                        result == ESP_OK ? "WiFi connecting" : "WiFi config failed"
                    );
                    feedback_until_ms = now + 2500;
                    break;
                }
                case PendingControlKind::kAudioOffer:
                    (void)cardbridge::device_audio_apply_offer(
                        pending_control.offer
                    );
                    publish_state(domain.state());
                    break;
                case PendingControlKind::kAudioReady:
                    (void)cardbridge::device_audio_mark_receiver_ready(
                        pending_control.session_id
                    );
                    break;
                case PendingControlKind::kConfigPrepare:
                    (void)cardbridge::device_shortcut_config_prepare(
                        pending_control.config_prepare.version,
                        pending_control.config_prepare.total_bytes,
                        pending_control.config_prepare.chunk_count,
                        pending_control.config_prepare.sha256.data()
                    );
                    break;
                case PendingControlKind::kConfigChunk:
                    (void)cardbridge::device_shortcut_config_put_chunk(
                        pending_control.config_chunk.index,
                        pending_control.config_chunk.offset,
                        pending_control.config_chunk.bytes.data(),
                        pending_control.config_chunk.size
                    );
                    break;
                case PendingControlKind::kConfigCommit: {
                    const auto result =
                        cardbridge::device_shortcut_config_commit();
                    if (result == cardbridge::DeviceConfigCommitResult::kAccepted) {
                        const std::size_t count =
                            cardbridge::device_shortcut_config_copy_mappings(
                                active_shortcuts.data(),
                                active_shortcuts.size()
                            );
                        (void)input_router.replace_mappings(
                            active_shortcuts.data(),
                            count
                        );
                        std::snprintf(
                            feedback,
                            sizeof(feedback),
                            "Config synced v%" PRIu64,
                            cardbridge::device_shortcut_config_version()
                        );
                    } else {
                        std::snprintf(
                            feedback,
                            sizeof(feedback),
                            "Config rejected %u",
                            static_cast<unsigned>(result)
                        );
                    }
                    feedback_until_ms = now + 2500;
                    publish_state(domain.state());
                    break;
                }
                case PendingControlKind::kShortcutLearnStart: {
                    apply_input_result(
                        input_router.begin_shortcut_learning(
                            pending_control.learn_token,
                            now
                        ),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    char event_json[112]{};
                    std::snprintf(
                        event_json,
                        sizeof(event_json),
                        "{\"v\":1,\"event\":\"shortcut_learning\",\"token\":%" PRIu32 "}",
                        pending_control.learn_token
                    );
                    (void)ble_bridge_notify_state(event_json);
                    std::snprintf(feedback, sizeof(feedback), "Press shortcut keys");
                    feedback_until_ms = now + cardbridge::kShortcutLearningTimeoutMs;
                    break;
                }
                case PendingControlKind::kShortcutLearnCancel:
                    apply_input_result(
                        input_router.cancel_shortcut_learning(
                            pending_control.learn_token
                        ),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    break;
                case PendingControlKind::kOTAStart: {
                    if (domain.state().mic_intent ==
                        cardbridge::MicIntent::kLive) {
                        domain.dispatch(
                            cardbridge::BridgeAction::kToggleMicIntent,
                            cardbridge::ActionSource::kBleControl
                        );
                    }
                    cardbridge::device_audio_set_capture_enabled(false);
                    const auto audio = cardbridge::device_audio_status();
                    const bool external_power = external_power_present() ||
                        pending_control.ota_start.usb_power_verified;
                    const int battery_level = std::clamp<std::int32_t>(
                        M5.Power.getBatteryLevel(),
                        -1,
                        100
                    );
                    g_battery_level.store(
                        battery_level,
                        std::memory_order_release
                    );
                    const auto readiness = cardbridge::firmware_update_readiness(
                        battery_level,
                        external_power,
                        audio.wifi_connected,
                        audio.wifi_rssi
                    );
                    const esp_err_t result = readiness ==
                            cardbridge::FirmwareUpdateReadiness::kReady
                        ? cardbridge::firmware_update_start(
                            pending_control.ota_start,
                            nullptr
                        )
                        : static_cast<esp_err_t>(
                            cardbridge::firmware_update_readiness_error(readiness)
                        );
                    std::snprintf(
                        feedback,
                        sizeof(feedback),
                        "%s",
                        result == ESP_OK ? "Updating firmware" : "Update unavailable"
                    );
                    feedback_until_ms = now + 2500;
                    publish_state(domain.state());
                    if (result != ESP_OK) {
                        char event_json[112]{};
                        std::snprintf(
                            event_json,
                            sizeof(event_json),
                            "{\"v\":1,\"event\":\"ota\",\"phase\":\"failed\",\"error\":%d}",
                            static_cast<int>(result)
                        );
                        (void)ble_bridge_notify_state(event_json);
                    }
                    break;
                }
            }
        }
        if (g_audio_offer_state_dirty.exchange(false, std::memory_order_acq_rel)) {
            publish_state(domain.state());
        }

        const auto audio_status = cardbridge::device_audio_status();
        const auto update_status = cardbridge::firmware_update_status();
        if (update_status.phase != last_update_status.phase ||
            update_status.progress != last_update_status.progress ||
            update_status.error != last_update_status.error) {
            const char* phase = "idle";
            switch (update_status.phase) {
                case cardbridge::FirmwareUpdatePhase::kIdle:
                    phase = "idle";
                    break;
                case cardbridge::FirmwareUpdatePhase::kDownloading:
                    phase = "downloading";
                    break;
                case cardbridge::FirmwareUpdatePhase::kRestarting:
                    phase = "restarting";
                    break;
                case cardbridge::FirmwareUpdatePhase::kFailed:
                    phase = "failed";
                    break;
            }
            char event_json[128]{};
            std::snprintf(
                event_json,
                sizeof(event_json),
                "{\"v\":1,\"event\":\"ota\",\"phase\":\"%s\",\"progress\":%u,\"error\":%d}",
                phase,
                static_cast<unsigned>(update_status.progress),
                static_cast<int>(update_status.error)
            );
            (void)ble_bridge_notify_state(event_json);
            last_update_status = update_status;
        }
        // An OTA image is only healthy when the two product-critical device
        // services have initialized. device_audio_start() fails before this
        // loop; keyboard_ready closes the remaining false-positive path.
        if (!running_image_confirmed && keyboard_ready && now >= 10'000) {
            const esp_err_t confirmation =
                cardbridge::firmware_update_confirm_running_image();
            if (confirmation == ESP_OK) {
                running_image_confirmed = true;
                std::printf(
                    "{\"v\":1,\"event\":\"firmware_health_confirmed\"}\n"
                );
            }
        }
        if (audio_status.wifi_connected != last_wifi_connected) {
            domain.dispatch(
                audio_status.wifi_connected
                    ? cardbridge::BridgeAction::kWifiAudioAuthenticated
                    : cardbridge::BridgeAction::kWifiAudioLost,
                cardbridge::ActionSource::kBleControl
            );
            publish_state(domain.state());
            last_wifi_connected = audio_status.wifi_connected;
        }
        if (audio_status.receiver_ready != last_audio_receiver_ready) {
            domain.dispatch(
                audio_status.receiver_ready
                    ? cardbridge::BridgeAction::kAudioSinkReady
                    : cardbridge::BridgeAction::kAudioSinkLost,
                cardbridge::ActionSource::kBleControl
            );
            publish_state(domain.state());
            last_audio_receiver_ready = audio_status.receiver_ready;
        }

        g0_recording_stop_guard.observe_button(M5.BtnA.isReleased(), now);
        if (M5.BtnA.wasPressed()) {
            should_wake_display = true;
            const bool activation_transaction_active =
                domain.state().mic_intent == cardbridge::MicIntent::kLive &&
                !g0_recording_stop_guard.stop_armed();
            if (activation_transaction_active) {
                activation_g0_press_ignored = true;
                pairing_g0_press = false;
                g0_press_stopped_microphone = false;
            } else {
                const bool stopped_microphone = stop_microphone_for_physical_press(
                    true,
                    false,
                    domain,
                    feedback,
                    sizeof(feedback),
                    feedback_until_ms
                );
                if (stopped_microphone) {
                    g0_recording_stop_guard.consume_stop();
                }
                if (pairing.visible && !stopped_microphone) {
                    pairing_g0_press = true;
                    g0_press_stopped_microphone = false;
                } else {
                    pairing_g0_press = false;
                    g0_press_stopped_microphone = stopped_microphone;
                    apply_input_result(
                        input_router.dispatch(cardbridge::InputAction{
                            cardbridge::InputActionKind::kG0Down, 0, 0, now}),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                }
            }
        }
        if (M5.BtnA.wasReleased()) {
            should_wake_display = true;
            if (activation_g0_press_ignored) {
                activation_g0_press_ignored = false;
                g0_press_stopped_microphone = false;
            } else if (pairing_g0_press) {
                if (pairing.visible && pairing.needs_confirmation) {
                    (void)ble_bridge_confirm_pairing(true);
                }
                pairing_g0_press = false;
                g0_press_stopped_microphone = false;
            } else {
                const bool intent_was_live =
                    domain.state().mic_intent == cardbridge::MicIntent::kLive;
                const auto release_kind = g0_press_stopped_microphone
                    ? cardbridge::InputActionKind::kG0UpShortcutOnly
                    : cardbridge::InputActionKind::kG0Up;
                g0_press_stopped_microphone = false;
                apply_input_result(
                    input_router.dispatch(cardbridge::InputAction{
                        release_kind, 0, 0, now}),
                    domain,
                    feedback,
                    sizeof(feedback),
                    feedback_until_ms
                );
                if (!intent_was_live &&
                    domain.state().mic_intent == cardbridge::MicIntent::kLive) {
                    g0_recording_stop_guard.recording_started(now);
                }
            }
        }

        std::array<cardbridge::CardputerKeyEvent, 16> key_events{};
        const auto key_event_count = keyboard.poll(key_events.data(), key_events.size());
        const bool keyboard_physical_press = keyboard.physical_press_observed();
        if (key_event_count > 0 || keyboard_physical_press) {
            should_wake_display = true;
        }
        const bool keyboard_stopped_microphone =
            stop_microphone_for_physical_press(
                keyboard_physical_press,
                false,
                domain,
                feedback,
                sizeof(feedback),
                feedback_until_ms
            );
        for (std::size_t index = 0; index < key_event_count; ++index) {
            const auto& event = key_events[index];
            if (!cardbridge::should_forward_after_microphone_stop(
                    keyboard_stopped_microphone,
                    event.pressed)) {
                continue;
            }
            apply_input_result(
                input_router.dispatch(cardbridge::InputAction{
                    event.pressed
                        ? cardbridge::InputActionKind::kKeyDown
                        : cardbridge::InputActionKind::kKeyUp,
                    event.usage,
                    event.modifiers,
                    now,
                }),
                domain,
                feedback,
                sizeof(feedback),
                feedback_until_ms
            );
        }
        apply_input_result(
            input_router.poll_shortcut_learning(now),
            domain,
            feedback,
            sizeof(feedback),
            feedback_until_ms
        );

        if (ble_bridge_take_disconnect_event()) {
            apply_input_result(
                input_router.dispatch(cardbridge::InputAction{
                    cardbridge::InputActionKind::kBleDisconnected, 0, 0, now}),
                domain,
                feedback,
                sizeof(feedback),
                feedback_until_ms
            );
        }

        const bool authenticated = ble_bridge_control_authenticated();
        if (authenticated && !last_authenticated) {
            apply_input_result(
                input_router.dispatch(cardbridge::InputAction{
                    cardbridge::InputActionKind::kBleAuthenticated, 0, 0, now}),
                domain,
                feedback,
                sizeof(feedback),
                feedback_until_ms
            );
            control_lease.authenticate(now);
            domain.dispatch(
                cardbridge::BridgeAction::kControlLinkAuthenticated,
                cardbridge::ActionSource::kBleControl
            );
            publish_state(domain.state());
        }
        last_authenticated = authenticated;

        const std::uint32_t pending_ble_heartbeats =
            g_ble_heartbeats_pending.exchange(0, std::memory_order_acq_rel);
        if (pending_ble_heartbeats > 0 && authenticated) {
            control_lease.heartbeat(now);
            last_heartbeat_ms = now;
            ble_heartbeat_total += pending_ble_heartbeats;
            if (!domain.state().ble_control_authenticated) {
                domain.dispatch(
                    cardbridge::BridgeAction::kControlLinkAuthenticated,
                    cardbridge::ActionSource::kBleControl
                );
                publish_state(domain.state());
            }
        }

        if (domain.state().ble_control_authenticated &&
            control_lease.expired(now, domain.state().mic_intent)) {
            domain.dispatch(
                cardbridge::BridgeAction::kControlLinkLost,
                cardbridge::ActionSource::kBleControl
            );
            publish_state(domain.state());
            std::snprintf(
                feedback,
                sizeof(feedback),
                "App heartbeat lost"
            );
            feedback_until_ms = now + 2500;
            emit_diagnostic_state(
                domain.state(),
                now,
                last_heartbeat_ms,
                ble_heartbeat_total,
                serial_heartbeat_total,
                "lease_expired"
            );
        }

        const int requested_mic_intent = g_remote_mic_intent_requested.exchange(
            kNoRemoteMicIntent,
            std::memory_order_acq_rel
        );
        if (requested_mic_intent != kNoRemoteMicIntent) {
            should_wake_display = true;
            const bool wants_live = requested_mic_intent == kRemoteMicLive;
            const bool is_live =
                domain.state().mic_intent == cardbridge::MicIntent::kLive;
            if (wants_live != is_live) {
                domain.dispatch(
                    cardbridge::BridgeAction::kToggleMicIntent,
                    cardbridge::ActionSource::kBleControl
                );
                if (!wants_live) {
                    cardbridge::device_audio_set_capture_enabled(false);
                }
                // Publish an exact baseline before capture starts and an exact
                // final count after it stops. The audio HIL can then observe
                // the production BLE/Wi-Fi path without opening USB Serial,
                // which resets a physical Cardputer ADV.
                publish_telemetry();
            }
            publish_state(domain.state());
        }

        cardbridge::device_audio_set_capture_enabled(
            domain.state().capture_gate == cardbridge::CaptureGate::kOpen
        );

        if (read_serial_command(
                serial_line.data(),
                serial_line.size(),
                serial_line_length)) {
            should_wake_display = true;
            const auto command = cardbridge::parse_serial_harness_command(
                std::string_view(serial_line.data(), serial_line_length)
            );
            serial_line_length = 0;
            switch (command) {
                case cardbridge::SerialHarnessCommand::kStatus:
                    break;
                case cardbridge::SerialHarnessCommand::kControlAuthenticate:
                    control_lease.authenticate(now);
                    domain.dispatch(
                        cardbridge::BridgeAction::kControlLinkAuthenticated,
                        cardbridge::ActionSource::kHarness
                    );
                    publish_state(domain.state());
                    break;
                case cardbridge::SerialHarnessCommand::kControlLost:
                    domain.dispatch(
                        cardbridge::BridgeAction::kControlLinkLost,
                        cardbridge::ActionSource::kHarness
                    );
                    publish_state(domain.state());
                    break;
                case cardbridge::SerialHarnessCommand::kHeartbeat:
                    if (!domain.state().ble_control_authenticated) {
                        control_lease.authenticate(now);
                        domain.dispatch(
                            cardbridge::BridgeAction::kControlLinkAuthenticated,
                            cardbridge::ActionSource::kHarness
                        );
                    } else {
                        control_lease.heartbeat(now);
                    }
                    last_heartbeat_ms = now;
                    ++serial_heartbeat_total;
                    publish_state(domain.state());
                    break;
                case cardbridge::SerialHarnessCommand::kMicLive:
                case cardbridge::SerialHarnessCommand::kMicMuted: {
                    const bool wants_live = command ==
                        cardbridge::SerialHarnessCommand::kMicLive;
                    const bool is_live = domain.state().mic_intent ==
                        cardbridge::MicIntent::kLive;
                    if (wants_live != is_live) {
                        domain.dispatch(
                            cardbridge::BridgeAction::kToggleMicIntent,
                            cardbridge::ActionSource::kHarness
                        );
                    }
                    publish_state(domain.state());
                    break;
                }
                case cardbridge::SerialHarnessCommand::kLedRed:
                    led_test_active = true;
                    led_test_until_ms = now + 20'000;
                    recording_led_policy.invalidate();
                    break;
                case cardbridge::SerialHarnessCommand::kLedOff:
                    led_test_active = false;
                    led_test_until_ms = 0;
                    recording_led_policy.invalidate();
                    break;
                case cardbridge::SerialHarnessCommand::kRebootBootloader:
                    // The firmware owns USB Serial/JTAG directly, so esptool's
                    // DTR/RTS reset hook is not active.  A physical USB-only
                    // harness command restores unattended future flashing.
                    std::printf(
                        "{\"v\":1,\"event\":\"rebooting\","
                        "\"target\":\"rom_bootloader\"}\n"
                    );
                    vTaskDelay(pdMS_TO_TICKS(50));
                    REG_WRITE(
                        RTC_CNTL_OPTION1_REG,
                        RTC_CNTL_FORCE_DOWNLOAD_BOOT
                    );
                    esp_restart();
                    break;
                case cardbridge::SerialHarnessCommand::kHidQ:
                    apply_input_result(
                        input_router.dispatch(cardbridge::InputAction{
                            cardbridge::InputActionKind::kKeyDown,
                            0x14,
                            0,
                            now,
                        }),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    vTaskDelay(pdMS_TO_TICKS(30));
                    apply_input_result(
                        input_router.dispatch(cardbridge::InputAction{
                            cardbridge::InputActionKind::kKeyUp,
                            0x14,
                            0,
                            uptime_ms(),
                        }),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    break;
                case cardbridge::SerialHarnessCommand::kHidG0Q:
                    apply_input_result(
                        input_router.dispatch(cardbridge::InputAction{
                            cardbridge::InputActionKind::kG0Down,
                            0,
                            0,
                            now,
                        }),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    apply_input_result(
                        input_router.dispatch(cardbridge::InputAction{
                            cardbridge::InputActionKind::kKeyDown,
                            0x14,
                            0,
                            now,
                        }),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    vTaskDelay(pdMS_TO_TICKS(30));
                    apply_input_result(
                        input_router.dispatch(cardbridge::InputAction{
                            cardbridge::InputActionKind::kKeyUp,
                            0x14,
                            0,
                            uptime_ms(),
                        }),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    apply_input_result(
                        input_router.dispatch(cardbridge::InputAction{
                            cardbridge::InputActionKind::kG0Up,
                            0,
                            0,
                            uptime_ms(),
                        }),
                        domain,
                        feedback,
                        sizeof(feedback),
                        feedback_until_ms
                    );
                    break;
                case cardbridge::SerialHarnessCommand::kInvalid:
                    std::printf(
                        "{\"v\":1,\"event\":\"error\","
                        "\"code\":\"invalid_serial_command\"}\n"
                    );
                    continue;
            }
            emit_diagnostic_state(
                domain.state(),
                now,
                last_heartbeat_ms,
                ble_heartbeat_total,
                serial_heartbeat_total,
                "serial"
            );
        }

        if (now >= next_telemetry_ms) {
            // Periodic JSON is a harness convenience, not a product data
            // path. Avoid formatting and pushing a large serial record while
            // live capture is sharing core 0 with the Wi-Fi/BLE stacks.
            if (domain.state().capture_gate != cardbridge::CaptureGate::kOpen) {
                emit_diagnostic_state(
                    domain.state(),
                    now,
                    last_heartbeat_ms,
                    ble_heartbeat_total,
                    serial_heartbeat_total,
                    "telemetry"
                );
            }
            next_telemetry_ms = now + 1000;
        }

        if (now >= next_battery_sample_ms) {
            g_battery_level.store(
                std::clamp<std::int32_t>(M5.Power.getBatteryLevel(), -1, 100),
                std::memory_order_release
            );
            g_external_power_present.store(
                external_power_present(),
                std::memory_order_release
            );
            // BLE and Wi-Fi share the ESP32-S3 radio. Battery telemetry is not
            // time critical, so never let its notification preempt live UDP
            // audio. The stop transition publishes a fresh snapshot.
            if (domain.state().capture_gate != cardbridge::CaptureGate::kOpen) {
                publish_telemetry();
            }
            next_battery_sample_ms = now + kBatterySampleIntervalMs;
        }

        if (should_wake_display) {
            last_local_activity_ms = now;
        }
        DisplayPowerState desired_display_power_state = DisplayPowerState::kActive;
        const bool capture_live = domain.state().capture_gate
            == cardbridge::CaptureGate::kOpen;
        if (!capture_live && !pairing.visible && !should_wake_display) {
            const auto idle_ms = now - last_local_activity_ms;
            if (idle_ms >= kDisplayOffAfterMs) {
                desired_display_power_state = DisplayPowerState::kOff;
            } else if (idle_ms >= kDisplayDimAfterMs) {
                desired_display_power_state = DisplayPowerState::kDim;
            }
        }
        const auto previous_display_power_state = display_power_state;
        apply_display_power_state(
            desired_display_power_state,
            display_power_state
        );
        if (previous_display_power_state == DisplayPowerState::kOff &&
            display_power_state != DisplayPowerState::kOff) {
            last_ui_signature = ~std::uint64_t{0};
        }

        if (led_test_active && now >= led_test_until_ms) {
            led_test_active = false;
            recording_led_policy.invalidate();
        }
        apply_recording_led_effect(
            recording_led_policy.reconcile(led_test_active || capture_live),
            display_power_state
        );

        const auto current_ui_signature = ui_signature(
            domain.state(),
            audio_status,
            keyboard_ready,
            feedback,
            feedback_until_ms,
            now
        );
        const bool waveform_due = domain.state().capture_gate
                == cardbridge::CaptureGate::kOpen
            && now >= next_wave_draw_ms;
        if (display_power_state != DisplayPowerState::kOff &&
            (current_ui_signature != last_ui_signature || waveform_due)) {
            draw_screen(
                screen,
                domain.state(),
                audio_status,
                keyboard_ready,
                feedback,
                feedback_until_ms,
                wave_phase++
            );
            last_ui_signature = current_ui_signature;
            next_wave_draw_ms = now + kLiveWaveformIntervalMs;
        }
        const auto loop_interval_ms =
            display_power_state == DisplayPowerState::kOff && !capture_live
            ? kIdleLoopIntervalMs
            : kActiveLoopIntervalMs;
        vTaskDelay(pdMS_TO_TICKS(loop_interval_ms));
    }
}
