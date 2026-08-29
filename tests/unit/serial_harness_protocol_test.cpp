#include "serial_harness_protocol.hpp"

#include <cstdlib>

namespace {

bool expect(
    const char* input,
    cardbridge::SerialHarnessCommand expected
) {
    return cardbridge::parse_serial_harness_command(input) == expected;
}

}  // namespace

int main() {
    using cardbridge::SerialHarnessCommand;
    if (!expect("status", SerialHarnessCommand::kStatus) ||
        !expect(" heartbeat\r\n", SerialHarnessCommand::kHeartbeat) ||
        !expect("mic live", SerialHarnessCommand::kMicLive) ||
        !expect("mic muted", SerialHarnessCommand::kMicMuted) ||
        !expect("led red", SerialHarnessCommand::kLedRed) ||
        !expect("led off", SerialHarnessCommand::kLedOff) ||
        !expect("reboot bootloader", SerialHarnessCommand::kRebootBootloader) ||
        !expect("control auth", SerialHarnessCommand::kControlAuthenticate) ||
        !expect("control lost", SerialHarnessCommand::kControlLost) ||
        !expect("hid q", SerialHarnessCommand::kHidQ) ||
        !expect("hid g0+q", SerialHarnessCommand::kHidG0Q) ||
        !expect("unknown", SerialHarnessCommand::kInvalid)) {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
