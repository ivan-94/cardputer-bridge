#include "control_lease.hpp"

namespace cardbridge {

namespace {

// BLE and Wi-Fi share one 2.4 GHz radio. Live heartbeats arrive every three
// seconds while UDP audio is live. Keep five delivery windows so several
// delayed acknowledged writes cannot turn a physical G0 recording into an
// unsolicited mute, while a vanished App still fails closed.
constexpr std::uint64_t kLiveLeaseMilliseconds = 15'000;
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
