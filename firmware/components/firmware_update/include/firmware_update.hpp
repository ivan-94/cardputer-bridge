#pragma once

#include "control_protocol.hpp"

#include <esp_err.h>

#include <cstdint>

namespace cardbridge {

enum class FirmwareUpdatePhase : std::uint8_t {
    kIdle,
    kDownloading,
    kRestarting,
    kFailed,
};

struct FirmwareUpdateStatus {
    FirmwareUpdatePhase phase{FirmwareUpdatePhase::kIdle};
    std::uint8_t progress = 0;
    esp_err_t error = ESP_OK;
};

using FirmwareUpdateNotify = void (*)(const FirmwareUpdateStatus& status);

// Starts a single background HTTPS OTA operation. The request must already
// have passed control_protocol's URL and version allow-list validation.
esp_err_t firmware_update_start(
    const OTAStart& request,
    FirmwareUpdateNotify notify
);

FirmwareUpdateStatus firmware_update_status();

// With rollback enabled, a newly installed image remains PENDING_VERIFY until
// the product's critical BLE, keyboard and audio services have stayed healthy.
esp_err_t firmware_update_confirm_running_image();

}  // namespace cardbridge
