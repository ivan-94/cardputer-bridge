#include "firmware_update_policy.hpp"

namespace cardbridge {

std::uint32_t firmware_connect_retry_delay_ms(
    std::uint8_t completed_attempts,
    FirmwareConnectFailure failure
) {
    if (failure != FirmwareConnectFailure::kTransport) return 0;
    switch (completed_attempts) {
        case 1:
            return 400;
        case 2:
            return 1200;
        default:
            return 0;
    }
}

FirmwareUpdateReadiness firmware_update_readiness(
    std::int32_t battery_percent,
    bool external_power,
    bool wifi_connected,
    std::int32_t wifi_rssi
) {
    if (!wifi_connected || wifi_rssi == 0) {
        return FirmwareUpdateReadiness::kWifiDisconnected;
    }
    if (!external_power && battery_percent < 0) {
        return FirmwareUpdateReadiness::kBatteryUnknown;
    }
    if (!external_power &&
        battery_percent < kFirmwareUpdateMinimumBatteryPercent) {
        return FirmwareUpdateReadiness::kLowBattery;
    }
    if (wifi_rssi < kFirmwareUpdateMinimumWifiRssi) {
        return FirmwareUpdateReadiness::kWeakWifi;
    }
    return FirmwareUpdateReadiness::kReady;
}

std::int32_t firmware_update_readiness_error(
    FirmwareUpdateReadiness readiness
) {
    switch (readiness) {
        case FirmwareUpdateReadiness::kReady:
            return 0;
        case FirmwareUpdateReadiness::kWifiDisconnected:
            return kFirmwareUpdateWifiDisconnectedError;
        case FirmwareUpdateReadiness::kBatteryUnknown:
            return kFirmwareUpdateBatteryUnknownError;
        case FirmwareUpdateReadiness::kLowBattery:
            return kFirmwareUpdateLowBatteryError;
        case FirmwareUpdateReadiness::kWeakWifi:
            return kFirmwareUpdateWeakWifiError;
    }
    return kFirmwareUpdateBatteryUnknownError;
}

}  // namespace cardbridge
