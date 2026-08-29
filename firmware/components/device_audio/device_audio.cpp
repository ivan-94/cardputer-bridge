#include "device_audio.hpp"

#include "audio_packet.hpp"

#include <M5Unified.h>
#include <esp_event.h>
#include <esp_netif.h>
#include <esp_timer.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <lwip/inet.h>
#include <lwip/sockets.h>
#include <psa/crypto.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <unistd.h>

namespace cardbridge {
namespace {

constexpr std::uint32_t kSampleRate = 16000;
constexpr std::size_t kTestPacketCount = 3;
constexpr std::uint32_t kInactiveAudioWaitMs = 250;
constexpr std::uint64_t kWifiTelemetryRefreshIntervalMs = 5000;

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
std::atomic_uint32_t s_udp_sent{0};
std::atomic_uint32_t s_udp_failures{0};
std::atomic_uint32_t s_capture_overruns{0};
std::atomic_uint32_t s_signal_level{0};
std::atomic_uint32_t s_idle_wait_total{0};
std::atomic_uint32_t s_notification_wake_total{0};
std::atomic_uint32_t s_wifi_telemetry_refresh_total{0};
std::atomic_int32_t s_wifi_rssi{0};
std::atomic_uint64_t s_last_wifi_telemetry_ms{0};
std::atomic<TaskHandle_t> s_audio_task_handle{nullptr};

void notify_audio_task() {
    const auto task = s_audio_task_handle.load(std::memory_order_acquire);
    if (task != nullptr) {
        xTaskNotifyGive(task);
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

void wifi_event(void*, esp_event_base_t base, std::int32_t id, void*) {
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        s_wifi_connected.store(true, std::memory_order_release);
        s_wifi_generation.fetch_add(1, std::memory_order_acq_rel);
        refresh_wifi_telemetry(true);
        notify_audio_task();
        return;
    }
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        s_wifi_connected.store(false, std::memory_order_release);
        s_receiver_ready.store(false, std::memory_order_release);
        s_wifi_rssi.store(0, std::memory_order_relaxed);
        s_last_wifi_telemetry_ms.store(0, std::memory_order_relaxed);
        if (s_wifi_configured.load(std::memory_order_acquire)) {
            (void)esp_wifi_connect();
        }
        notify_audio_task();
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

bool seal_and_send(
    int socket_fd,
    const sockaddr_in& target,
    psa_key_id_t key_id,
    const AudioOffer& offer,
    const std::int16_t* samples,
    std::uint8_t flags,
    std::uint32_t sequence,
    std::uint32_t capture_sample_index
) {
    std::array<std::uint8_t, kAudioDatagramBytes> datagram{};
    const AudioPacketHeader header{
        flags,
        offer.session_id,
        sequence,
        capture_sample_index,
        kAudioFrameSamples,
        kAudioPayloadBytes,
    };
    if (!encode_audio_header(header, datagram.data(), datagram.size())) {
        return false;
    }
    std::array<std::uint8_t, kAudioNonceBytes> nonce{};
    make_audio_nonce(offer.session_id, sequence, nonce.data());
    const auto* plaintext = reinterpret_cast<const std::uint8_t*>(samples);
    std::uint8_t* ciphertext = datagram.data() + kAudioHeaderBytes;
    std::size_t encrypted_size = 0;
    if (psa_aead_encrypt(
            key_id,
            PSA_ALG_GCM,
            nonce.data(),
            nonce.size(),
            datagram.data(),
            kAudioHeaderBytes,
            plaintext,
            kAudioPayloadBytes,
            ciphertext,
            kAudioPayloadBytes + kAudioAuthTagBytes,
            &encrypted_size) != PSA_SUCCESS ||
        encrypted_size != kAudioPayloadBytes + kAudioAuthTagBytes) {
        return false;
    }
    return sendto(
        socket_fd,
        datagram.data(),
        datagram.size(),
        0,
        reinterpret_cast<const sockaddr*>(&target),
        sizeof(target)
    ) == static_cast<ssize_t>(datagram.size());
}

void audio_task(void*) {
    s_audio_task_handle.store(
        xTaskGetCurrentTaskHandle(),
        std::memory_order_release
    );
    std::array<std::array<std::int16_t, kAudioFrameSamples>, 2> sample_buffers{};
    const std::array<std::int16_t, kAudioFrameSamples> silence{};
    std::size_t completed_buffer_index = 0;
    std::uint32_t active_generation = 0;
    std::uint32_t active_wifi_generation = 0;
    std::uint32_t sequence = 0;
    std::uint32_t sample_index = 0;
    bool mic_running = false;
    bool capture_pipeline_active = false;
    int socket_fd = -1;
    AudioOffer offer{};
    sockaddr_in target{};
    psa_key_id_t key_id = 0;
    if (psa_crypto_init() != PSA_SUCCESS) {
        s_udp_failures.fetch_add(1, std::memory_order_relaxed);
        s_audio_task_handle.store(nullptr, std::memory_order_release);
        vTaskDelete(nullptr);
        return;
    }

    while (true) {
        const std::uint32_t generation = s_offer_generation.load(
            std::memory_order_acquire
        );
        if (!s_wifi_connected.load(std::memory_order_acquire) ||
            generation == 0 || !copy_offer(offer)) {
            if (mic_running) {
                M5.Mic.end();
                mic_running = false;
                capture_pipeline_active = false;
            }
            wait_for_audio_work();
            continue;
        }

        const bool offer_changed = generation != active_generation;
        if (offer_changed) {
            if (mic_running) {
                M5.Mic.end();
                mic_running = false;
                capture_pipeline_active = false;
            }
            if (socket_fd >= 0) {
                close(socket_fd);
            }
            socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
            target = {};
            target.sin_family = AF_INET;
            target.sin_port = htons(offer.port);
            if (socket_fd < 0 ||
                inet_pton(AF_INET, offer.ipv4.data(), &target.sin_addr) != 1) {
                s_udp_failures.fetch_add(1, std::memory_order_relaxed);
                vTaskDelay(pdMS_TO_TICKS(100));
                continue;
            }
            if (key_id != 0) {
                (void)psa_destroy_key(key_id);
                key_id = 0;
            }
            psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
            psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_ENCRYPT);
            psa_set_key_algorithm(&attributes, PSA_ALG_GCM);
            psa_set_key_type(&attributes, PSA_KEY_TYPE_AES);
            psa_set_key_bits(&attributes, offer.key.size() * 8);
            const psa_status_t import_status = psa_import_key(
                &attributes,
                offer.key.data(),
                offer.key.size(),
                &key_id
            );
            psa_reset_key_attributes(&attributes);
            if (import_status != PSA_SUCCESS) {
                s_udp_failures.fetch_add(1, std::memory_order_relaxed);
                vTaskDelay(pdMS_TO_TICKS(100));
                continue;
            }
            sequence = 0;
            sample_index = 0;
            s_receiver_ready.store(false, std::memory_order_release);
            active_generation = generation;
        }

        const std::uint32_t wifi_generation = s_wifi_generation.load(
            std::memory_order_acquire
        );
        if (offer_changed || wifi_generation != active_wifi_generation) {
            s_receiver_ready.store(false, std::memory_order_release);
            for (std::size_t index = 0; index < kTestPacketCount; ++index) {
                if (seal_and_send(
                        socket_fd,
                        target,
                        key_id,
                        offer,
                        silence.data(),
                        kAudioFlagMuted | kAudioFlagTest,
                        sequence++,
                        sample_index)) {
                    s_udp_sent.fetch_add(1, std::memory_order_relaxed);
                } else {
                    s_udp_failures.fetch_add(1, std::memory_order_relaxed);
                }
                sample_index += kAudioFrameSamples;
                vTaskDelay(pdMS_TO_TICKS(20));
            }
            active_wifi_generation = wifi_generation;
        }

        if (!s_receiver_ready.load(std::memory_order_acquire) ||
            !s_capture_enabled.load(std::memory_order_acquire)) {
            if (mic_running) {
                M5.Mic.end();
                mic_running = false;
                capture_pipeline_active = false;
            }
            wait_for_audio_work();
            continue;
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

        const auto& samples = sample_buffers[completed_buffer_index];
        std::uint64_t absolute_sum = 0;
        for (const auto sample : samples) {
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
        if (seal_and_send(
                socket_fd,
                target,
                key_id,
                offer,
                samples.data(),
                0,
                sequence++,
                sample_index)) {
            s_udp_sent.fetch_add(1, std::memory_order_relaxed);
        } else {
            s_udp_failures.fetch_add(1, std::memory_order_relaxed);
        }
        sample_index += kAudioFrameSamples;

        // Re-submit the buffer only after transport is done reading it. The
        // other queued buffer covers this work, so recording stays gapless.
        auto& capture = sample_buffers[completed_buffer_index];
        if (M5.Mic.record(
                capture.data(),
                capture.size(),
                kSampleRate,
                false)) {
            completed_buffer_index ^= 1U;
        } else {
            s_capture_overruns.fetch_add(1, std::memory_order_relaxed);
            M5.Mic.end();
            mic_running = false;
            capture_pipeline_active = false;
        }
    }
}

}  // namespace

esp_err_t device_audio_start() {
    bool expected = false;
    if (!s_started.compare_exchange_strong(expected, true)) {
        return ESP_OK;
    }
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
    BaseType_t task_result = xTaskCreate(
        audio_task,
        "audio_tx",
        8192,
        nullptr,
        1,
        nullptr
    );
    return task_result == pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
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
    taskENTER_CRITICAL(&s_lock);
    s_offer = offer;
    taskEXIT_CRITICAL(&s_lock);
    s_offer_active.store(true, std::memory_order_release);
    s_receiver_ready.store(false, std::memory_order_release);
    s_offer_generation.fetch_add(1, std::memory_order_acq_rel);
    notify_audio_task();
    return true;
}

bool device_audio_mark_receiver_ready(std::uint64_t session_id) {
    AudioOffer offer{};
    if (!copy_offer(offer) || offer.session_id != session_id) return false;
    s_receiver_ready.store(true, std::memory_order_release);
    notify_audio_task();
    return true;
}

void device_audio_set_capture_enabled(bool enabled) {
    const bool previous = s_capture_enabled.exchange(
        enabled,
        std::memory_order_acq_rel
    );
    if (previous != enabled) {
        (void)esp_wifi_set_ps(enabled ? WIFI_PS_NONE : WIFI_PS_MIN_MODEM);
        notify_audio_task();
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
        s_udp_sent.load(std::memory_order_relaxed),
        s_udp_failures.load(std::memory_order_relaxed),
        s_capture_overruns.load(std::memory_order_relaxed),
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
    const auto task = s_audio_task_handle.load(std::memory_order_acquire);
    return task == nullptr
        ? 0
        : static_cast<std::uint32_t>(uxTaskGetStackHighWaterMark(task));
}

}  // namespace cardbridge
