#pragma once

#include "bridge_domain.hpp"

#include <cstdint>

namespace cardbridge {

class ControlLease {
public:
    void authenticate(std::uint64_t now_ms);
    void heartbeat(std::uint64_t now_ms);
    bool expired(std::uint64_t now_ms, MicIntent mic_intent) const;

private:
    bool authenticated_{false};
    std::uint64_t last_heartbeat_ms_{0};
};

}  // namespace cardbridge
