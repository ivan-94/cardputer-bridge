#include "control_lease.hpp"

namespace cardbridge {

namespace {

// macOS may negotiate a power-saving BLE connection whose acknowledged GATT
// write cadence is roughly 300-350 ms. Keep three observed delivery windows of
// margin while still failing closed quickly when the App disappears.
constexpr std::uint64_t kLiveLeaseMilliseconds = 1'200;
constexpr std::uint64_t kMutedLeaseMilliseconds = 3'000;

}  // namespace

void ControlLease::authenticate(std::uint64_t now_ms) {
    authenticated_ = true;
    last_heartbeat_ms_ = now_ms;
}

void ControlLease::heartbeat(std::uint64_t now_ms) {
    if (authenticated_) {
        last_heartbeat_ms_ = now_ms;
    }
}

bool ControlLease::expired(
    std::uint64_t now_ms,
    MicIntent mic_intent
) const {
    const std::uint64_t lease_milliseconds = mic_intent == MicIntent::kLive
        ? kLiveLeaseMilliseconds
        : kMutedLeaseMilliseconds;
    return authenticated_
        && now_ms - last_heartbeat_ms_ >= lease_milliseconds;
}

}  // namespace cardbridge
