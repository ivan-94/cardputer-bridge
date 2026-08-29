#pragma once

#include <string_view>

namespace cardbridge {

enum class SerialHarnessCommand {
    kInvalid,
    kStatus,
    kHeartbeat,
    kMicLive,
    kMicMuted,
    kLedRed,
    kLedOff,
    kRebootBootloader,
    kControlAuthenticate,
    kControlLost,
    kHidQ,
    kHidG0Q,
};

SerialHarnessCommand parse_serial_harness_command(std::string_view input);

}  // namespace cardbridge
