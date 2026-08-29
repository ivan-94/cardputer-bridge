#include "recording_led.hpp"

#include <cstdlib>
#include <iostream>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

}  // namespace

int main() {
    using cardbridge::RecordingLedEffect;
    cardbridge::RecordingLedPolicy policy;

    require(
        policy.reconcile(false) == RecordingLedEffect::kOff,
        "boot must explicitly turn the recording LED off"
    );
    require(
        policy.reconcile(false) == RecordingLedEffect::kNoChange,
        "stable muted state must not retransmit LED frames"
    );
    require(
        policy.reconcile(true) == RecordingLedEffect::kSolidRed,
        "open capture gate must request a solid red LED"
    );
    for (int frame = 0; frame < 1000; ++frame) {
        require(
            policy.reconcile(true) == RecordingLedEffect::kNoChange,
            "stable recording state must not refresh or blink the LED"
        );
    }
    require(
        policy.reconcile(false) == RecordingLedEffect::kOff,
        "closing capture gate must turn the recording LED off"
    );
    require(
        policy.reconcile(false) == RecordingLedEffect::kNoChange,
        "stable off state must not retransmit LED frames"
    );
    return EXIT_SUCCESS;
}
