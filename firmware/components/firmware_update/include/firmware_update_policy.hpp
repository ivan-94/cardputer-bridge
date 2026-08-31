#pragma once

#include <cstdint>

namespace cardbridge {

enum class FirmwareConnectFailure : std::uint8_t {
    kTransport,
    kPermanent,
};

enum class FirmwareUpdateReadiness : std::uint8_t {
    kReady,
    kWifiDisconnected,
    kBatteryUnknown,
    kLowBattery,
    kWeakWifi,
};

constexpr std::int32_t kFirmwareUpdateWifiDisconnectedError = 0x7101;
constexpr std::int32_t kFirmwareUpdateBatteryUnknownError = 0x7102;
constexpr std::int32_t kFirmwareUpdateLowBatteryError = 0x7103;
constexpr std::int32_t kFirmwareUpdateWeakWifiError = 0x7104;
constexpr std::int32_t kFirmwareUpdateMinimumBatteryPercent = 30;
constexpr std::int32_t kFirmwareUpdateMinimumWifiRssi = -80;

// completed_attempts is one-based. A zero delay means fail immediately.
std::uint32_t firmware_connect_retry_delay_ms(
    std::uint8_t completed_attempts,
    FirmwareConnectFailure failure
);

// Evaluated once, immediately before OTA starts. Transient RSSI changes during
// an active update are deliberately handled by the transport retry policy.
FirmwareUpdateReadiness firmware_update_readiness(
    std::int32_t battery_percent,
    bool external_power,
    bool wifi_connected,
    std::int32_t wifi_rssi
);

std::int32_t firmware_update_readiness_error(FirmwareUpdateReadiness readiness);

}  // namespace cardbridge
