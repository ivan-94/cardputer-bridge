#include "firmware_update.hpp"

#include <esp_app_desc.h>
#include <esp_crt_bundle.h>
#include <esp_https_ota.h>
#include <esp_ota_ops.h>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <new>

namespace cardbridge {
namespace {

struct UpdateContext {
    OTAStart request{};
    FirmwareUpdateNotify notify = nullptr;
};

std::atomic_bool g_running{false};
std::atomic_uint8_t g_phase{
    static_cast<std::uint8_t>(FirmwareUpdatePhase::kIdle)};
std::atomic_uint8_t g_progress{0};
std::atomic_int g_error{ESP_OK};

void publish(
    FirmwareUpdatePhase phase,
    std::uint8_t progress,
    esp_err_t error,
    FirmwareUpdateNotify notify
) {
    g_phase.store(static_cast<std::uint8_t>(phase), std::memory_order_release);
    g_progress.store(progress, std::memory_order_release);
    g_error.store(error, std::memory_order_release);
    if (notify != nullptr) {
        notify(FirmwareUpdateStatus{phase, progress, error});
    }
}

bool parse_version(const char* value, std::array<unsigned, 3>& numbers) {
    if (value == nullptr) return false;
    const char* cursor = value;
    for (std::size_t index = 0; index < numbers.size(); ++index) {
        if (*cursor < '0' || *cursor > '9') return false;
        unsigned number = 0;
        unsigned digits = 0;
        while (*cursor >= '0' && *cursor <= '9') {
            if (++digits > 3) return false;
            number = number * 10U + static_cast<unsigned>(*cursor - '0');
            ++cursor;
        }
        numbers[index] = number;
        if (index + 1 < numbers.size()) {
            if (*cursor != '.') return false;
            ++cursor;
        }
    }
    return *cursor == '\0';
}

bool is_strictly_newer(const char* candidate, const char* current) {
    std::array<unsigned, 3> candidate_numbers{};
    std::array<unsigned, 3> current_numbers{};
    if (!parse_version(candidate, candidate_numbers) ||
        !parse_version(current, current_numbers)) {
        return false;
    }
    return candidate_numbers > current_numbers;
}

void update_task(void* argument) {
    auto* context = static_cast<UpdateContext*>(argument);
    const auto notify = context->notify;
    publish(FirmwareUpdatePhase::kDownloading, 0, ESP_OK, notify);

    esp_http_client_config_t http_config{};
    http_config.url = context->request.url.data();
    http_config.crt_bundle_attach = esp_crt_bundle_attach;
    http_config.timeout_ms = 15'000;
    http_config.keep_alive_enable = true;
    http_config.max_redirection_count = 5;

    esp_https_ota_config_t ota_config{};
    ota_config.http_config = &http_config;

    esp_https_ota_handle_t handle = nullptr;
    esp_err_t result = esp_https_ota_begin(&ota_config, &handle);
    if (result != ESP_OK) {
        publish(FirmwareUpdatePhase::kFailed, 0, result, notify);
        g_running.store(false, std::memory_order_release);
        delete context;
        vTaskDelete(nullptr);
        return;
    }

    esp_app_desc_t candidate{};
    const esp_app_desc_t* running = esp_app_get_description();
    result = esp_https_ota_get_img_desc(handle, &candidate);
    if (result == ESP_OK &&
        std::strcmp(candidate.project_name, "cardputer_bridge_firmware") != 0) {
        result = ESP_ERR_OTA_VALIDATE_FAILED;
    }
    if (result == ESP_OK &&
        std::strcmp(candidate.version, context->request.version.data()) != 0) {
        result = ESP_ERR_INVALID_VERSION;
    }
    if (result == ESP_OK &&
        !is_strictly_newer(candidate.version, running->version)) {
        result = ESP_ERR_INVALID_VERSION;
    }

    int last_progress = -1;
    while (result == ESP_OK) {
        result = esp_https_ota_perform(handle);
        const int total = esp_https_ota_get_image_size(handle);
        const int received = esp_https_ota_get_image_len_read(handle);
        const int progress = total > 0 && received >= 0
            ? std::clamp(received * 100 / total, 0, 99)
            : 0;
        if (progress >= last_progress + 5) {
            last_progress = progress;
            publish(
                FirmwareUpdatePhase::kDownloading,
                static_cast<std::uint8_t>(progress),
                ESP_OK,
                notify
            );
        }
        if (result == ESP_ERR_HTTPS_OTA_IN_PROGRESS) {
            result = ESP_OK;
            continue;
        }
        break;
    }

    if (result == ESP_OK && !esp_https_ota_is_complete_data_received(handle)) {
        result = ESP_ERR_INVALID_SIZE;
    }
    if (result == ESP_OK) {
        result = esp_https_ota_finish(handle);
        handle = nullptr;
    }
    if (handle != nullptr) {
        (void)esp_https_ota_abort(handle);
    }

    if (result != ESP_OK) {
        publish(FirmwareUpdatePhase::kFailed, 0, result, notify);
        g_running.store(false, std::memory_order_release);
        delete context;
        vTaskDelete(nullptr);
        return;
    }

    publish(FirmwareUpdatePhase::kRestarting, 100, ESP_OK, notify);
    delete context;
    vTaskDelay(pdMS_TO_TICKS(750));
    esp_restart();
}

}  // namespace

esp_err_t firmware_update_start(
    const OTAStart& request,
    FirmwareUpdateNotify notify
) {
    bool expected = false;
    if (!g_running.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acq_rel)) {
        return ESP_ERR_INVALID_STATE;
    }
    auto* context = new (std::nothrow) UpdateContext{request, notify};
    if (context == nullptr) {
        g_running.store(false, std::memory_order_release);
        return ESP_ERR_NO_MEM;
    }
    const BaseType_t created = xTaskCreate(
        update_task,
        "firmware_ota",
        8192,
        context,
        4,
        nullptr
    );
    if (created != pdPASS) {
        delete context;
        g_running.store(false, std::memory_order_release);
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

FirmwareUpdateStatus firmware_update_status() {
    return FirmwareUpdateStatus{
        static_cast<FirmwareUpdatePhase>(
            g_phase.load(std::memory_order_acquire)),
        g_progress.load(std::memory_order_acquire),
        static_cast<esp_err_t>(g_error.load(std::memory_order_acquire)),
    };
}

esp_err_t firmware_update_confirm_running_image() {
    const esp_partition_t* running = esp_ota_get_running_partition();
    esp_ota_img_states_t state{};
    const esp_err_t state_result = esp_ota_get_state_partition(running, &state);
    if (state_result == ESP_ERR_NOT_SUPPORTED ||
        (state_result == ESP_OK && state != ESP_OTA_IMG_PENDING_VERIFY)) {
        return ESP_OK;
    }
    if (state_result != ESP_OK) return state_result;
    return esp_ota_mark_app_valid_cancel_rollback();
}

}  // namespace cardbridge
