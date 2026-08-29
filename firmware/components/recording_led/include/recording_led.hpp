#pragma once

namespace cardbridge {

enum class RecordingLedEffect {
    kNoChange,
    kOff,
    kSolidRed,
};

class RecordingLedPolicy {
public:
    RecordingLedEffect reconcile(bool capture_open);
    void invalidate();

private:
    bool initialized_{false};
    bool capture_open_{false};
};

}  // namespace cardbridge
