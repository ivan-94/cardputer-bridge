#include "firmware_update_policy.hpp"

#include <cstdlib>
#include <iostream>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

}  // namespace

int main() {
    using cardbridge::FirmwareConnectFailure;
    using cardbridge::FirmwareUpdateReadiness;

    require(
        cardbridge::firmware_connect_retry_delay_ms(
            1,
            FirmwareConnectFailure::kTransport
        ) == 400,
        "first transport failure should retry after a short backoff"
    );
    require(
        cardbridge::firmware_connect_retry_delay_ms(
            2,
            FirmwareConnectFailure::kTransport
        ) == 1200,
        "second transport failure should retry after a longer backoff"
    );
    require(
        cardbridge::firmware_connect_retry_delay_ms(
            3,
            FirmwareConnectFailure::kTransport
        ) == 0,
        "third transport failure should stop retrying"
    );
    require(
        cardbridge::firmware_connect_retry_delay_ms(
            1,
            FirmwareConnectFailure::kPermanent
        ) == 0,
        "permanent failures must fail fast"
    );

    require(
        cardbridge::firmware_update_readiness(29, false, true, -60) ==
            FirmwareUpdateReadiness::kLowBattery,
        "battery below 30 percent should block OTA without external power"
    );
    require(
        cardbridge::firmware_update_readiness(0, true, true, -60) ==
            FirmwareUpdateReadiness::kReady,
        "external power should allow OTA with a low battery"
    );
    require(
        cardbridge::firmware_update_readiness(80, false, true, -81) ==
            FirmwareUpdateReadiness::kWeakWifi,
        "Wi-Fi weaker than -80 dBm should block OTA before it starts"
    );
    require(
        cardbridge::firmware_update_readiness(80, false, true, -80) ==
            FirmwareUpdateReadiness::kReady,
        "-80 dBm should remain an accepted boundary value"
    );
    require(
        cardbridge::firmware_update_readiness(80, false, false, 0) ==
            FirmwareUpdateReadiness::kWifiDisconnected,
        "disconnected Wi-Fi should block OTA"
    );
    require(
        cardbridge::firmware_update_readiness(-1, false, true, -60) ==
            FirmwareUpdateReadiness::kBatteryUnknown,
        "unknown battery state should fail fast without external power"
    );
    require(
        cardbridge::firmware_update_readiness(-1, true, true, -60) ==
            FirmwareUpdateReadiness::kReady,
        "external power should make an unknown battery state safe"
    );

    std::cout << "PASS firmware_update_policy\n";
    return EXIT_SUCCESS;
}
