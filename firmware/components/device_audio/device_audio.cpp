#include "device_audio.hpp"

#include "audio_frame_ring.hpp"
#include "audio_packet.hpp"

#include <M5Unified.h>
#include <esp_event.h>
#include <esp_log.h>
#include <esp_netif.h>
#include <esp_timer.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <lwip/inet.h>
#include <lwip/sockets.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace cardbridge {
namespace {

constexpr std::uint32_t kSampleRate = 16000;
// The receiver activates after any run of three contiguous current-session
// proofs. Repeat a short burst while waiting so ARP resolution, transient
// coexistence stalls, or isolated UDP loss cannot strand the session.
constexpr std::size_t kTestPacketCount = 5;
constexpr std::size_t kEndPacketCount = 3;
constexpr std::uint64_t kProofRetryIntervalMs = 500;
constexpr std::uint32_t kInactiveAudioWaitMs = 250;
constexpr std::uint64_t kWifiTelemetryRefreshIntervalMs = 5000;
// Twenty-millisecond frames make ten slots a 200 ms hard upper bound. UDP
// sends are nonblocking, so a larger queue would only turn scheduler pressure
// into stale audio and user-visible latency.
constexpr std::size_t kCaptureRingFrames = 10;
constexpr std::size_t kSendRetryCount = 3;
constexpr std::uint32_t kSendRetryDelayMs = 1;
// DSCP Expedited Forwarding. Access points with WMM map this traffic to the
// voice queue, reducing the chance that BLE coexistence or ordinary LAN load
// turns a sequence of timely UDP sends into one late delivery burst.
constexpr int kAudioIPTypeOfService = 0xB8;
constexpr BaseType_t kCaptureTaskCore = 1;
constexpr BaseType_t kTransportTaskCore = 1;
constexpr UBaseType_t kMicrophoneTaskPriority = 10;
constexpr UBaseType_t kCaptureTaskPriority = 8;
// I2S owns the hard sample clock. Once a completed frame reaches the capture
// ring, drain it before the next 20 ms frame arrives. All three tasks stay on
// core 1; Wi-Fi, Bluetooth and the UI run on core 0 in this firmware build.
constexpr UBaseType_t kTransportTaskPriority = 9;

portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
std::array<std::uint8_t, 33> s_staged_ssid{};
std::size_t s_staged_ssid_size = 0;
std::array<std::uint8_t, 64> s_staged_password{};
std::size_t s_staged_password_size = 0;
std::array<char, 33> s_wifi_ssid{};
AudioOffer s_offer{};

std::atomic_bool s_started{false};
std::atomic_bool s_wifi_configured{false};
std::atomic_bool s_wifi_connected{false};
std::atomic_bool s_offer_active{false};
std::atomic_bool s_receiver_ready{false};
std::atomic_bool s_capture_enabled{false};
std::atomic_uint32_t s_offer_generation{0};
std::atomic_uint32_t s_wifi_generation{0};
std::atomic_uint32_t s_next_wire_sequence{0};
std::atomic_uint32_t s_stream_frames_sent{0};
std::atomic_uint32_t s_stream_failures{0};
std::atomic_int32_t s_last_stream_error{0};
std::atomic_uint32_t s_capture_overruns{0};
std::atomic_uint32_t s_microphone_record_failures{0};
std::atomic_uint32_t s_capture_ring_drops{0};
std::atomic_uint32_t s_capture_ring_high_water{0};
std::atomic_uint32_t s_maximum_capture_gap_ms{0};
std::atomic_uint32_t s_maximum_transport_gap_ms{0};
std::atomic_uint32_t s_wifi_disconnect_count{0};
std::atomic_int32_t s_last_wifi_disconnect_reason{0};
std::atomic_uint32_t s_signal_level{0};
std::atomic_uint32_t s_idle_wait_total{0};
std::atomic_uint32_t s_notification_wake_total{0};
std::atomic_uint32_t s_wifi_telemetry_refresh_total{0};
std::atomic_int32_t s_wifi_rssi{0};
std::atomic_uint64_t s_last_wifi_telemetry_ms{0};
std::atomic<TaskHandle_t> s_capture_task_handle{nullptr};
std::atomic<TaskHandle_t> s_transport_task_handle{nullptr};
AudioFrameRing<kCaptureRingFrames> s_capture_ring;

// UDP redundancy needs several MTU-sized buffers, but their lifetime is the
// whole transport task. Keep them in BSS instead of consuming the task stack
// while lwIP also needs call depth.
struct AudioTransportWorkspace {
    std::array<std::int16_t, kAudioFrameSamples> silence{};
    CapturedAudioFrame captured{};
    std::array<
        std::array<std::uint8_t, kAudioStreamFrameBytes>,
        kAudioRedundancyLagFrames
    > redundancy_history{};
    std::array<std::uint32_t, kAudioRedundancyLagFrames>
        redundancy_history_sequences{};
    std::array<std::uint32_t, kAudioRedundancyLagFrames>
        redundancy_history_capture_indices{};
    std::array<std::uint8_t, kAudioStreamFrameBytes> current{};
    std::array<std::uint8_t, kAudioRedundantDatagramBytes> datagram{};
};

AudioTransportWorkspace s_transport_workspace;

void notify_task(const std::atomic<TaskHandle_t>& handle) {
    const auto task = handle.load(std::memory_order_acquire);
    if (task != nullptr) {
        xTaskNotifyGive(task);
    }
}

void notify_audio_tasks() {
    notify_task(s_capture_task_handle);
    notify_task(s_transport_task_handle);
}

void record_maximum(std::atomic_uint32_t& destination, std::uint32_t value) {
    auto current = destination.load(std::memory_order_relaxed);
    while (value > current && !destination.compare_exchange_weak(
               current,
               value,
               std::memory_order_relaxed,
               std::memory_order_relaxed)) {
    }
}

void wait_for_audio_work() {
    s_idle_wait_total.fetch_add(1, std::memory_order_relaxed);
    if (ulTaskNotifyTake(
            pdTRUE,
            pdMS_TO_TICKS(kInactiveAudioWaitMs)) > 0) {
        s_notification_wake_total.fetch_add(1, std::memory_order_relaxed);
    }
}

bool set_runtime_wifi_power_save(wifi_ps_type_t mode) {
    const auto result = esp_wifi_set_ps(mode);
    if (result == ESP_OK) return true;
    s_last_stream_error.store(
        -2000 - static_cast<std::int32_t>(result),
        std::memory_order_relaxed
    );
    s_stream_failures.fetch_add(1, std::memory_order_relaxed);
    ESP_LOGE(
        "audio-wifi",
        "wifi power-save transition failed mode=%d error=%s",
        static_cast<int>(mode),
        esp_err_to_name(result)
    );
    return false;
}

void cache_wifi_ssid(const wifi_config_t& config) {
    std::array<char, 33> sanitized{};
    const auto length = strnlen(
        reinterpret_cast<const char*>(config.sta.ssid),
        sizeof(config.sta.ssid)
    );
    const auto copy_length = std::min(length, sanitized.size() - 1);
    for (std::size_t index = 0; index < copy_length; ++index) {
        const auto value = static_cast<char>(config.sta.ssid[index]);
        sanitized[index] = (value == '"' || value == '\\') ? '_' : value;
    }
    taskENTER_CRITICAL(&s_lock);
    s_wifi_ssid = sanitized;
    taskEXIT_CRITICAL(&s_lock);
}

void refresh_wifi_telemetry(bool force) {
    if (!s_wifi_connected.load(std::memory_order_acquire)) {
        s_wifi_rssi.store(0, std::memory_order_relaxed);
        return;
    }
    const auto now_ms = static_cast<std::uint64_t>(esp_timer_get_time() / 1000);
    auto last_ms = s_last_wifi_telemetry_ms.load(std::memory_order_relaxed);
    if (!force && (now_ms <= last_ms ||
                   now_ms - last_ms < kWifiTelemetryRefreshIntervalMs)) {
        return;
    }
    if (force) {
        s_last_wifi_telemetry_ms.store(now_ms, std::memory_order_relaxed);
    } else if (!s_last_wifi_telemetry_ms.compare_exchange_strong(
                   last_ms,
                   now_ms,
                   std::memory_order_relaxed)) {
        return;
    }

    wifi_ap_record_t access_point{};
    s_wifi_telemetry_refresh_total.fetch_add(1, std::memory_order_relaxed);
    if (esp_wifi_sta_get_ap_info(&access_point) == ESP_OK) {
        s_wifi_rssi.store(access_point.rssi, std::memory_order_relaxed);
    }
    wifi_config_t config{};
    if (esp_wifi_get_config(WIFI_IF_STA, &config) == ESP_OK) {
        cache_wifi_ssid(config);
    }
}

void wifi_event(void*, esp_event_base_t base, std::int32_t id, void* event_data) {
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        s_wifi_connected.store(true, std::memory_order_release);
        s_wifi_generation.fetch_add(1, std::memory_order_acq_rel);
        refresh_wifi_telemetry(true);
        notify_audio_tasks();
        return;
    }
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        const auto* disconnected = static_cast<const wifi_event_sta_disconnected_t*>(
            event_data
        );
        const auto reason = disconnected == nullptr ? 0 : disconnected->reason;
        const auto disconnect_count =
            s_wifi_disconnect_count.fetch_add(1, std::memory_order_relaxed) + 1;
        s_last_wifi_disconnect_reason.store(reason, std::memory_order_relaxed);
        ESP_LOGW(
            "audio-wifi",
            "[DEBUG-wifi-drop-a17c] reason=%u count=%u",
            static_cast<unsigned>(reason),
            static_cast<unsigned>(disconnect_count)
        );
        s_wifi_connected.store(false, std::memory_order_release);
        s_receiver_ready.store(false, std::memory_order_release);
        s_wifi_rssi.store(0, std::memory_order_relaxed);
        s_last_wifi_telemetry_ms.store(0, std::memory_order_relaxed);
        if (s_wifi_configured.load(std::memory_order_acquire)) {
            (void)esp_wifi_connect();
        }
        notify_audio_tasks();
    }
}

bool copy_offer(AudioOffer& result) {
    if (!s_offer_active.load(std::memory_order_acquire)) {
        return false;
    }
    taskENTER_CRITICAL(&s_lock);
    result = s_offer;
    taskEXIT_CRITICAL(&s_lock);
    return true;
}

bool same_audio_offer(const AudioOffer& left, const AudioOffer& right) {
    return left.ipv4 == right.ipv4 &&
        left.port == right.port &&
        left.session_id == right.session_id;
}

bool encode_audio_frame(
    const AudioOffer& offer,
    const std::int16_t* samples,
    std::uint8_t flags,
    std::uint32_t sequence,
    std::uint32_t capture_sample_index,
    std::uint8_t* stream_frame,
    std::size_t stream_frame_size
) {
    if (stream_frame == nullptr || stream_frame_size < kAudioStreamFrameBytes) {
        return false;
    }
    const AudioPacketHeader header{
        flags,
        offer.session_id,
        sequence,
        capture_sample_index,
        kAudioFrameSamples,
        kAudioPayloadBytes,
    };
    return encode_audio_packet(header, samples, stream_frame, stream_frame_size);
}

bool send_datagram(int socket_fd, const std::uint8_t* bytes, std::size_t size) {
    for (std::size_t attempt = 0; attempt <= kSendRetryCount; ++attempt) {
        const auto result = send(socket_fd, bytes, size, 0);
        if (result == static_cast<ssize_t>(size)) return true;
        const auto error = result < 0 ? errno : -1002;
        const bool queue_pressure = error == ENOMEM || error == EAGAIN ||
            error == EWOULDBLOCK;
        if (queue_pressure && attempt < kSendRetryCount) {
            // Capture has its own task and a bounded 200 ms ring. Yielding a
            // millisecond here lets lwIP retire a TX buffer without blocking
            // the microphone clock or turning pressure into silent loss.
            vTaskDelay(pdMS_TO_TICKS(kSendRetryDelayMs));
            continue;
        }
        s_last_stream_error.store(error, std::memory_order_relaxed);
        return false;
    }
    return false;
}

bool encode_and_send(
    int socket_fd,
    const AudioOffer& offer,
    const std::int16_t* samples,
    std::uint8_t flags,
    std::uint32_t sequence,
    std::uint32_t capture_sample_index
) {
    std::array<std::uint8_t, kAudioStreamFrameBytes> stream_frame{};
    return encode_audio_frame(
        offer,
        samples,
        flags,
        sequence,
        capture_sample_index,
        stream_frame.data(),
        stream_frame.size()
    ) && send_datagram(socket_fd, stream_frame.data(), stream_frame.size());
}

std::size_t send_session_proofs(
    int socket_fd,
    const AudioOffer& offer,
    const std::int16_t* silence
) {
    std::size_t sent = 0;
    for (std::size_t index = 0; index < kTestPacketCount; ++index) {
        const auto sequence = s_next_wire_sequence.fetch_add(
            1,
            std::memory_order_relaxed
        );
        if (encode_and_send(
                socket_fd,
                offer,
                silence,
                kAudioFlagMuted | kAudioFlagTest,
                sequence,
                0)) {
            s_stream_frames_sent.fetch_add(1, std::memory_order_relaxed);
            ++sent;
        } else {
            s_stream_failures.fetch_add(1, std::memory_order_relaxed);
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    if (sent == kTestPacketCount) {
        s_last_stream_error.store(0, std::memory_order_relaxed);
    }
    return sent;
}

int connect_audio_stream(const AudioOffer& offer) {
    const int socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_fd < 0) return -1;
    if (setsockopt(
            socket_fd,
            IPPROTO_IP,
            IP_TOS,
            &kAudioIPTypeOfService,
            sizeof(kAudioIPTypeOfService)) != 0) {
        close(socket_fd);
        return -1;
    }
    sockaddr_in target{};
    target.sin_family = AF_INET;
    target.sin_port = htons(offer.port);
    if (inet_pton(AF_INET, offer.ipv4.data(), &target.sin_addr) != 1 ||
        connect(
            socket_fd,
            reinterpret_cast<const sockaddr*>(&target),
            sizeof(target)
        ) != 0) {
        close(socket_fd);
        return -1;
    }
    // UDP connect only records the peer locally and does not wait for network
    // traffic. Switch to nonblocking after it succeeds: lwIP may otherwise
    // report EINPROGRESS and make a healthy endpoint look unavailable.
    const int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(socket_fd);
        return -1;
    }
    return socket_fd;
}

void audio_capture_task(void*) {
    s_capture_task_handle.store(
        xTaskGetCurrentTaskHandle(),
        std::memory_order_release
    );
    std::array<std::array<std::int16_t, kAudioFrameSamples>, 2> sample_buffers{};
    std::size_t completed_buffer_index = 0;
    std::uint32_t active_generation = 0;
    std::uint32_t sample_index = 0;
    bool mic_running = false;
    bool capture_pipeline_active = false;
    std::uint64_t previous_capture_complete_us = 0;

    while (true) {
        const std::uint32_t generation = s_offer_generation.load(
            std::memory_order_acquire
        );
        const bool should_capture =
            s_wifi_connected.load(std::memory_order_acquire) &&
            s_receiver_ready.load(std::memory_order_acquire) &&
            s_capture_enabled.load(std::memory_order_acquire) &&
            generation != 0;
        if (!should_capture) {
            if (mic_running) {
                M5.Mic.end();
                mic_running = false;
                capture_pipeline_active = false;
                previous_capture_complete_us = 0;
            }
            wait_for_audio_work();
            continue;
        }

        if (generation != active_generation) {
            if (mic_running) {
                M5.Mic.end();
                mic_running = false;
                capture_pipeline_active = false;
            }
            sample_index = 0;
            active_generation = generation;
            previous_capture_complete_us = 0;
        }

        if (!capture_pipeline_active) {
            bool pipeline_ready = true;
            for (auto& capture : sample_buffers) {
                if (!M5.Mic.record(
                        capture.data(),
                        capture.size(),
                        kSampleRate,
                        false)) {
                    pipeline_ready = false;
                    break;
                }
            }
            if (!pipeline_ready) {
                M5.Mic.end();
                mic_running = false;
                s_capture_overruns.fetch_add(1, std::memory_order_relaxed);
                s_microphone_record_failures.fetch_add(1, std::memory_order_relaxed);
                vTaskDelay(1);
                continue;
            }
            mic_running = true;
            capture_pipeline_active = true;
            completed_buffer_index = 0;
        }
        // A queue depth of two means both buffers still belong to the mic
        // worker. As soon as one completes, process it while the other keeps
        // I2S capture continuous; never let the DMA-facing queue run dry.
        while (M5.Mic.isRecording() == sample_buffers.size()) {
            vTaskDelay(1);
        }
        if (!s_capture_enabled.load(std::memory_order_acquire) ||
            !s_receiver_ready.load(std::memory_order_acquire) ||
            generation != s_offer_generation.load(std::memory_order_acquire)) {
            M5.Mic.end();
            mic_running = false;
            capture_pipeline_active = false;
            previous_capture_complete_us = 0;
            continue;
        }

        const auto& samples = sample_buffers[completed_buffer_index];
        const auto capture_complete_us = static_cast<std::uint64_t>(
            esp_timer_get_time()
        );
        if (previous_capture_complete_us != 0 &&
            capture_complete_us >= previous_capture_complete_us) {
            record_maximum(
                s_maximum_capture_gap_ms,
                static_cast<std::uint32_t>(
                    (capture_complete_us - previous_capture_complete_us) / 1000
                )
            );
        }
        previous_capture_complete_us = capture_complete_us;
        CapturedAudioFrame frame{};
        frame.samples = samples;
        frame.offer_generation = generation;
        frame.sequence = s_next_wire_sequence.fetch_add(
            1,
            std::memory_order_relaxed
        );
        frame.capture_sample_index = sample_index;
        sample_index += kAudioFrameSamples;

        std::uint64_t absolute_sum = 0;
        for (const auto sample : frame.samples) {
            const std::int32_t wide = sample;
            absolute_sum += static_cast<std::uint32_t>(wide < 0 ? -wide : wide);
        }
        const auto average = absolute_sum / samples.size();
        s_signal_level.store(
            static_cast<std::uint32_t>(std::min<std::uint64_t>(
                1000,
                average * 1000 / 32768
            )),
            std::memory_order_relaxed
        );
        if (!s_capture_ring.try_push(frame)) {
            s_capture_overruns.fetch_add(1, std::memory_order_relaxed);
            s_capture_ring_drops.fetch_add(1, std::memory_order_relaxed);
        } else {
            record_maximum(
                s_capture_ring_high_water,
                static_cast<std::uint32_t>(s_capture_ring.size())
            );
            notify_task(s_transport_task_handle);
        }

        // Only a fixed-size memory copy happens before this re-submit. Network
        // connection, packet encoding and writes live on the transport task.
        auto& capture = sample_buffers[completed_buffer_index];
        if (M5.Mic.record(
                capture.data(),
                capture.size(),
                kSampleRate,
                false)) {
            completed_buffer_index ^= 1U;
        } else {
            s_capture_overruns.fetch_add(1, std::memory_order_relaxed);
            s_microphone_record_failures.fetch_add(1, std::memory_order_relaxed);
            M5.Mic.end();
            mic_running = false;
            capture_pipeline_active = false;
            previous_capture_complete_us = 0;
        }
    }
}

void audio_transport_task(void*) {
    s_transport_task_handle.store(
        xTaskGetCurrentTaskHandle(),
        std::memory_order_release
    );
    auto& workspace = s_transport_workspace;
    std::uint32_t active_generation = 0;
    std::uint32_t active_wifi_generation = 0;
    int socket_fd = -1;
    AudioOffer offer{};
    std::size_t redundancy_history_count = 0;
    std::size_t redundancy_history_cursor = 0;
    bool last_frame_valid = false;
    std::uint32_t last_capture_sample_index = 0;
    std::uint64_t last_proof_attempt_ms = 0;
    bool recording_interval_active = false;
    std::uint64_t previous_live_send_us = 0;

    while (true) {
        const auto generation = s_offer_generation.load(std::memory_order_acquire);
        if (!s_wifi_connected.load(std::memory_order_acquire) ||
            generation == 0 || !copy_offer(offer)) {
            if (socket_fd >= 0) {
                close(socket_fd);
                socket_fd = -1;
            }
            s_receiver_ready.store(false, std::memory_order_release);
            s_capture_ring.clear();
            redundancy_history_count = 0;
            redundancy_history_cursor = 0;
            last_frame_valid = false;
            recording_interval_active = false;
            previous_live_send_us = 0;
            wait_for_audio_work();
            continue;
        }

        const bool offer_changed = generation != active_generation;
        if (offer_changed) {
            if (socket_fd >= 0) close(socket_fd);
            socket_fd = -1;
            s_next_wire_sequence.store(0, std::memory_order_release);
            s_receiver_ready.store(false, std::memory_order_release);
            s_capture_ring.clear();
            redundancy_history_count = 0;
            redundancy_history_cursor = 0;
            last_frame_valid = false;
            recording_interval_active = false;
            previous_live_send_us = 0;
            active_generation = generation;
            active_wifi_generation = 0;
            last_proof_attempt_ms = 0;
        }

        const auto wifi_generation = s_wifi_generation.load(
            std::memory_order_acquire
        );
        const bool needs_connection =
            socket_fd < 0 || wifi_generation != active_wifi_generation;
        if (needs_connection) {
            if (socket_fd >= 0) close(socket_fd);
            socket_fd = connect_audio_stream(offer);
            if (socket_fd < 0) {
                s_last_stream_error.store(
                    errno == 0 ? -1001 : errno,
                    std::memory_order_relaxed
                );
                s_stream_failures.fetch_add(1, std::memory_order_relaxed);
                vTaskDelay(pdMS_TO_TICKS(100));
                continue;
            }
            s_receiver_ready.store(false, std::memory_order_release);
            s_capture_ring.clear();
            redundancy_history_count = 0;
            redundancy_history_cursor = 0;
            last_frame_valid = false;
            recording_interval_active = false;
            previous_live_send_us = 0;
            active_wifi_generation = wifi_generation;
            last_proof_attempt_ms = 0;
        }

        if (!s_receiver_ready.load(std::memory_order_acquire)) {
            const auto now_ms = static_cast<std::uint64_t>(
                esp_timer_get_time() / 1000
            );
            if (last_proof_attempt_ms == 0 ||
                now_ms - last_proof_attempt_ms >= kProofRetryIntervalMs) {
                (void)send_session_proofs(
                    socket_fd,
                    offer,
                    workspace.silence.data()
                );
                last_proof_attempt_ms = now_ms;
            }
            s_capture_ring.clear();
            redundancy_history_count = 0;
            redundancy_history_cursor = 0;
            last_frame_valid = false;
            recording_interval_active = false;
            wait_for_audio_work();
            continue;
        }

        const bool capture_enabled = s_capture_enabled.load(
            std::memory_order_acquire
        );
        if (capture_enabled) {
            recording_interval_active = true;
        } else if (!recording_interval_active) {
            s_capture_ring.clear();
            redundancy_history_count = 0;
            redundancy_history_cursor = 0;
            last_frame_valid = false;
            wait_for_audio_work();
            continue;
        }

        auto& frame = workspace.captured;
        if (!s_capture_ring.try_pop(frame)) {
            if (!capture_enabled && recording_interval_active) {
                // Close the interval explicitly. The receiver intentionally
                // holds five frames for reordering, so silence alone cannot
                // flush the final 100 ms. Three repeated
                // end markers make the close robust without replaying audio.
                const auto end_capture_index = last_frame_valid
                    ? last_capture_sample_index + kAudioFrameSamples
                    : 0;
                for (std::size_t index = 0; index < kEndPacketCount; ++index) {
                    const auto end_sequence = s_next_wire_sequence.fetch_add(
                        1,
                        std::memory_order_relaxed
                    );
                    if (encode_and_send(
                            socket_fd,
                            offer,
                            workspace.silence.data(),
                            kAudioFlagMuted | kAudioFlagEnd,
                            end_sequence,
                            end_capture_index)) {
                        s_stream_frames_sent.fetch_add(1, std::memory_order_relaxed);
                    } else {
                        s_stream_failures.fetch_add(1, std::memory_order_relaxed);
                    }
                    vTaskDelay(1);
                }
                recording_interval_active = false;
                previous_live_send_us = 0;
                redundancy_history_count = 0;
                redundancy_history_cursor = 0;
                last_frame_valid = false;
            }
            (void)ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));
            continue;
        }
        if (!s_receiver_ready.load(std::memory_order_acquire)) {
            s_capture_ring.clear();
            recording_interval_active = false;
            continue;
        }
        if (frame.offer_generation != active_generation) continue;
        const bool frame_valid = encode_audio_frame(
            offer,
            frame.samples.data(),
            0,
            frame.sequence,
            frame.capture_sample_index,
            workspace.current.data(),
            workspace.current.size()
        );
        const std::uint8_t* datagram_bytes = workspace.current.data();
        std::size_t datagram_size = workspace.current.size();
        if (frame_valid &&
            redundancy_history_count == kAudioRedundancyLagFrames &&
            audio_frames_match_redundancy_lag(
                workspace.redundancy_history_sequences[
                    redundancy_history_cursor
                ],
                workspace.redundancy_history_capture_indices[
                    redundancy_history_cursor
                ],
                frame.sequence,
                frame.capture_sample_index
            )) {
            std::copy(
                workspace.redundancy_history[redundancy_history_cursor].begin(),
                workspace.redundancy_history[redundancy_history_cursor].end(),
                workspace.datagram.begin()
            );
            std::copy(
                workspace.current.begin(),
                workspace.current.end(),
                workspace.datagram.begin() + kAudioStreamFrameBytes
            );
            datagram_bytes = workspace.datagram.data();
            datagram_size = workspace.datagram.size();
        }
        if (frame_valid && send_datagram(socket_fd, datagram_bytes, datagram_size)) {
            s_stream_frames_sent.fetch_add(1, std::memory_order_relaxed);
            const auto now_us = static_cast<std::uint64_t>(esp_timer_get_time());
            if (previous_live_send_us != 0 && now_us >= previous_live_send_us) {
                record_maximum(
                    s_maximum_transport_gap_ms,
                    static_cast<std::uint32_t>(
                        (now_us - previous_live_send_us) / 1000
                    )
                );
            }
            previous_live_send_us = now_us;
        } else {
            if (!frame_valid) {
                s_last_stream_error.store(-1003, std::memory_order_relaxed);
            }
            s_stream_failures.fetch_add(1, std::memory_order_relaxed);
        }
        if (frame_valid) {
            workspace.redundancy_history[redundancy_history_cursor] =
                workspace.current;
            workspace.redundancy_history_sequences[redundancy_history_cursor] =
                frame.sequence;
            workspace.redundancy_history_capture_indices[
                redundancy_history_cursor
            ] = frame.capture_sample_index;
            redundancy_history_cursor =
                (redundancy_history_cursor + 1) % kAudioRedundancyLagFrames;
            redundancy_history_count = std::min<std::size_t>(
                redundancy_history_count + 1,
                kAudioRedundancyLagFrames
            );
            last_frame_valid = true;
            last_capture_sample_index = frame.capture_sample_index;
        }
    }
}

}  // namespace

esp_err_t device_audio_start() {
    bool expected = false;
    if (!s_started.compare_exchange_strong(expected, true)) {
        return ESP_OK;
    }
    // The microphone worker drains I2S DMA and therefore has the only hard
    // realtime deadline in this pipeline. M5Unified otherwise creates it as an
    // unpinned priority-2 task, where Wi-Fi/BLE activity can delay capture long
    // enough to create audible holes without any UDP sequence loss.
    auto microphone_config = M5.Mic.config();
    microphone_config.task_priority = kMicrophoneTaskPriority;
    microphone_config.task_pinned_core = kCaptureTaskCore;
    M5.Mic.config(microphone_config);
    esp_err_t result = esp_netif_init();
    if (result != ESP_OK && result != ESP_ERR_INVALID_STATE) return result;
    result = esp_event_loop_create_default();
    if (result != ESP_OK && result != ESP_ERR_INVALID_STATE) return result;
    (void)esp_netif_create_default_wifi_sta();
    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    result = esp_wifi_init(&config);
    if (result != ESP_OK) return result;
    result = esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, nullptr);
    if (result != ESP_OK) return result;
    result = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, nullptr);
    if (result != ESP_OK) return result;
    result = esp_wifi_set_storage(WIFI_STORAGE_FLASH);
    if (result != ESP_OK) return result;
    result = esp_wifi_set_mode(WIFI_MODE_STA);
    if (result != ESP_OK) return result;
    result = esp_wifi_start();
    if (result != ESP_OK) return result;
    // Stay energy-efficient while muted. Capture switches this to WIFI_PS_NONE
    // because beacon batching otherwise becomes audible packet jitter.
    result = esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
    if (result != ESP_OK) return result;
    wifi_config_t persisted_config{};
    if (esp_wifi_get_config(WIFI_IF_STA, &persisted_config) == ESP_OK &&
        persisted_config.sta.ssid[0] != 0) {
        cache_wifi_ssid(persisted_config);
        s_wifi_configured.store(true, std::memory_order_release);
        (void)esp_wifi_connect();
    }
    std::fill(
        persisted_config.sta.password,
        persisted_config.sta.password + sizeof(persisted_config.sta.password),
        0
    );
    TaskHandle_t capture_task = nullptr;
    BaseType_t task_result = xTaskCreatePinnedToCore(
        audio_capture_task,
        "audio_capture",
        4096,
        nullptr,
        kCaptureTaskPriority,
        &capture_task,
        kCaptureTaskCore
    );
    if (task_result != pdPASS) return ESP_ERR_NO_MEM;
    TaskHandle_t transport_task = nullptr;
    task_result = xTaskCreatePinnedToCore(
        audio_transport_task,
        "audio_stream",
        8192,
        nullptr,
        kTransportTaskPriority,
        &transport_task,
        kTransportTaskCore
    );
    if (task_result != pdPASS) {
        vTaskDelete(capture_task);
        s_capture_task_handle.store(nullptr, std::memory_order_release);
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

bool device_audio_stage_ssid(const std::uint8_t* value, std::size_t length) {
    if (value == nullptr || length == 0 || length > 32) return false;
    taskENTER_CRITICAL(&s_lock);
    std::fill(s_staged_ssid.begin(), s_staged_ssid.end(), 0);
    std::copy(value, value + length, s_staged_ssid.begin());
    s_staged_ssid_size = length;
    taskEXIT_CRITICAL(&s_lock);
    return true;
}

bool device_audio_stage_password(const std::uint8_t* value, std::size_t length) {
    if (value == nullptr || length < 8 || length > 63) return false;
    taskENTER_CRITICAL(&s_lock);
    std::fill(s_staged_password.begin(), s_staged_password.end(), 0);
    std::copy(value, value + length, s_staged_password.begin());
    s_staged_password_size = length;
    taskEXIT_CRITICAL(&s_lock);
    return true;
}

esp_err_t device_audio_commit_wifi() {
    wifi_config_t config{};
    taskENTER_CRITICAL(&s_lock);
    const bool valid = s_staged_ssid_size > 0 && s_staged_password_size >= 8;
    if (valid) {
        std::copy_n(s_staged_ssid.begin(), s_staged_ssid_size, config.sta.ssid);
        std::copy_n(
            s_staged_password.begin(),
            s_staged_password_size,
            config.sta.password
        );
    }
    std::fill(s_staged_password.begin(), s_staged_password.end(), 0);
    s_staged_password_size = 0;
    taskEXIT_CRITICAL(&s_lock);
    if (!valid) return ESP_ERR_INVALID_ARG;
    (void)esp_wifi_disconnect();
    esp_err_t result = esp_wifi_set_config(WIFI_IF_STA, &config);
    if (result == ESP_OK) {
        cache_wifi_ssid(config);
        s_wifi_configured.store(true, std::memory_order_release);
        result = esp_wifi_connect();
    }
    std::fill(config.sta.password, config.sta.password + sizeof(config.sta.password), 0);
    return result;
}

bool device_audio_apply_offer(const AudioOffer& offer) {
    if (offer.port == 0 || offer.session_id == 0 || offer.ipv4[0] == '\0') {
        return false;
    }
    bool unchanged = false;
    taskENTER_CRITICAL(&s_lock);
    unchanged = s_offer_active.load(std::memory_order_relaxed) &&
        same_audio_offer(s_offer, offer);
    taskEXIT_CRITICAL(&s_lock);
    if (unchanged) {
        if (!s_receiver_ready.load(std::memory_order_acquire)) {
            if (!set_runtime_wifi_power_save(WIFI_PS_NONE)) return false;
        }
        notify_audio_tasks();
        return true;
    }
    s_receiver_ready.store(false, std::memory_order_release);
    // Session establishment is short and latency-sensitive. Beacon batching
    // here can lose the entire proof burst before live capture even starts.
    if (!set_runtime_wifi_power_save(WIFI_PS_NONE)) return false;
    taskENTER_CRITICAL(&s_lock);
    s_offer = offer;
    taskEXIT_CRITICAL(&s_lock);
    s_offer_active.store(true, std::memory_order_release);
    s_offer_generation.fetch_add(1, std::memory_order_acq_rel);
    notify_audio_tasks();
    return true;
}

bool device_audio_mark_receiver_ready(std::uint64_t session_id) {
    AudioOffer offer{};
    if (!copy_offer(offer) || offer.session_id != session_id) return false;
    if (!set_runtime_wifi_power_save(
            s_capture_enabled.load(std::memory_order_acquire)
                ? WIFI_PS_NONE
                : WIFI_PS_MIN_MODEM)) {
        return false;
    }
    s_receiver_ready.store(true, std::memory_order_release);
    notify_audio_tasks();
    return true;
}

void device_audio_set_capture_enabled(bool enabled) {
    const bool previous = s_capture_enabled.exchange(
        enabled,
        std::memory_order_acq_rel
    );
    if (previous != enabled) {
        (void)set_runtime_wifi_power_save(
            enabled ? WIFI_PS_NONE : WIFI_PS_MIN_MODEM
        );
        // Keep the ESP32 coexistence scheduler balanced. Hard Wi-Fi priority
        // can starve the BLE heartbeat long enough to trip the fail-closed
        // control lease. Disabling Wi-Fi power save while live keeps UDP
        // datagrams timely without suppressing the BLE control plane.
        notify_audio_tasks();
    }
    if (!enabled) {
        s_signal_level.store(0, std::memory_order_relaxed);
    }
}

DeviceAudioStatus device_audio_status() {
    const bool connected = s_wifi_connected.load(std::memory_order_acquire);
    refresh_wifi_telemetry(false);
    DeviceAudioStatus status{
        connected,
        s_offer_active.load(std::memory_order_acquire),
        s_receiver_ready.load(std::memory_order_acquire),
        s_capture_enabled.load(std::memory_order_acquire),
        static_cast<std::uint16_t>(s_signal_level.load(std::memory_order_relaxed)),
        connected ? s_wifi_rssi.load(std::memory_order_relaxed) : 0,
        {},
        s_stream_frames_sent.load(std::memory_order_relaxed),
        s_stream_failures.load(std::memory_order_relaxed),
        s_last_stream_error.load(std::memory_order_relaxed),
        s_capture_overruns.load(std::memory_order_relaxed),
        s_microphone_record_failures.load(std::memory_order_relaxed),
        s_capture_ring_drops.load(std::memory_order_relaxed),
        s_capture_ring_high_water.load(std::memory_order_relaxed),
        s_maximum_capture_gap_ms.load(std::memory_order_relaxed),
        s_maximum_transport_gap_ms.load(std::memory_order_relaxed),
        s_wifi_disconnect_count.load(std::memory_order_relaxed),
        s_last_wifi_disconnect_reason.load(std::memory_order_relaxed),
        s_idle_wait_total.load(std::memory_order_relaxed),
        s_notification_wake_total.load(std::memory_order_relaxed),
        s_wifi_telemetry_refresh_total.load(std::memory_order_relaxed),
    };
    taskENTER_CRITICAL(&s_lock);
    status.wifi_ssid = s_wifi_ssid;
    taskEXIT_CRITICAL(&s_lock);
    return status;
}

std::uint32_t device_audio_stack_high_water_words() {
    const auto capture = s_capture_task_handle.load(std::memory_order_acquire);
    const auto transport = s_transport_task_handle.load(std::memory_order_acquire);
    if (capture == nullptr || transport == nullptr) return 0;
    return static_cast<std::uint32_t>(std::min(
        uxTaskGetStackHighWaterMark(capture),
        uxTaskGetStackHighWaterMark(transport)
    ));
}

}  // namespace cardbridge
