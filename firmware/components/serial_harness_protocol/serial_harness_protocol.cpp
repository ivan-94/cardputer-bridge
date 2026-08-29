#include "serial_harness_protocol.hpp"

namespace cardbridge {
namespace {

bool is_space(char value) {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

std::string_view trim(std::string_view input) {
    while (!input.empty() && is_space(input.front())) {
        input.remove_prefix(1);
    }
    while (!input.empty() && is_space(input.back())) {
        input.remove_suffix(1);
    }
    return input;
}

}  // namespace

SerialHarnessCommand parse_serial_harness_command(std::string_view input) {
    input = trim(input);
    if (input == "status") {
        return SerialHarnessCommand::kStatus;
    }
    if (input == "heartbeat") {
        return SerialHarnessCommand::kHeartbeat;
    }
    if (input == "mic live") {
        return SerialHarnessCommand::kMicLive;
    }
    if (input == "mic muted") {
        return SerialHarnessCommand::kMicMuted;
    }
    if (input == "led red") {
        return SerialHarnessCommand::kLedRed;
    }
    if (input == "led off") {
        return SerialHarnessCommand::kLedOff;
    }
    if (input == "reboot bootloader") {
        return SerialHarnessCommand::kRebootBootloader;
    }
    if (input == "control auth") {
        return SerialHarnessCommand::kControlAuthenticate;
    }
    if (input == "control lost") {
        return SerialHarnessCommand::kControlLost;
    }
    if (input == "hid q") {
        return SerialHarnessCommand::kHidQ;
    }
    if (input == "hid g0+q") {
        return SerialHarnessCommand::kHidG0Q;
    }
    return SerialHarnessCommand::kInvalid;
}

}  // namespace cardbridge
