#include "recording_led.hpp"

namespace cardbridge {

RecordingLedEffect RecordingLedPolicy::reconcile(bool capture_open) {
    if (initialized_ && capture_open_ == capture_open) {
        return RecordingLedEffect::kNoChange;
    }
    initialized_ = true;
    capture_open_ = capture_open;
    return capture_open
        ? RecordingLedEffect::kSolidRed
        : RecordingLedEffect::kOff;
}

void RecordingLedPolicy::invalidate() {
    initialized_ = false;
}

}  // namespace cardbridge
