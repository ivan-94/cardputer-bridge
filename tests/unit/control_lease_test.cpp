#include "bridge_domain.hpp"
#include "control_lease.hpp"

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
    cardbridge::BridgeDomain domain;
    domain.reset(cardbridge::ResetProfile::kReadyMuted);
    domain.dispatch(
        cardbridge::BridgeAction::kToggleMicIntent,
        cardbridge::ActionSource::kHarness
    );

    cardbridge::ControlLease lease;
    lease.authenticate(1'000);
    lease.heartbeat(1'000);

    // A live heartbeat is scheduled every three seconds. Losing several
    // acknowledged BLE writes while Wi-Fi audio owns the shared radio must not
    // turn a physical G0 recording into an unsolicited mute.
    require(!lease.expired(15'999, cardbridge::MicIntent::kLive),
            "a live control lease must tolerate four missed heartbeat cycles");
    require(lease.expired(16'000, cardbridge::MicIntent::kLive),
            "a live control lease must eventually fail closed after 15000 ms");

    if (lease.expired(16'000, cardbridge::MicIntent::kLive)) {
        domain.dispatch(
            cardbridge::BridgeAction::kControlLinkLost,
            cardbridge::ActionSource::kBleControl
        );
    }

    require(domain.state().mic_intent == cardbridge::MicIntent::kMuted,
            "an expired live control lease must clear the user's live intent");
    require(domain.state().capture_gate == cardbridge::CaptureGate::kClosed,
            "an expired live control lease must fail closed");

    cardbridge::ControlLease muted_lease;
    muted_lease.authenticate(5'000);
    muted_lease.heartbeat(5'000);
    require(!muted_lease.expired(7'999, cardbridge::MicIntent::kMuted),
            "a muted control lease must survive before three missed cycles");
    require(muted_lease.expired(8'000, cardbridge::MicIntent::kMuted),
            "a muted control lease must expire after three missed one-second cycles");

    std::cout << "PASS live_control_lease_expires_and_fails_closed\n";
    std::cout << "PASS muted_control_lease_expires_after_three_cycles\n";
    return EXIT_SUCCESS;
}
