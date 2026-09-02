#include "cardputer_adv_input.hpp"

#include <M5Unified.h>

namespace cardbridge {
namespace {

constexpr std::uint8_t kAddress = 0x34;
constexpr std::uint32_t kI2cFrequency = 100000;
constexpr std::uint8_t kRegConfig = 0x01;
constexpr std::uint8_t kRegInterruptStatus = 0x02;
constexpr std::uint8_t kRegEventCount = 0x03;
constexpr std::uint8_t kRegFirstEvent = 0x04;
constexpr std::uint8_t kRegKeypadGpio1 = 0x1d;
constexpr std::uint8_t kRegKeypadGpio2 = 0x1e;
constexpr std::uint8_t kRegKeypadGpio3 = 0x1f;
constexpr std::uint8_t kRegGpiEventMode1 = 0x20;
constexpr std::uint8_t kRegGpiEventMode2 = 0x21;
constexpr std::uint8_t kRegGpiEventMode3 = 0x22;
constexpr std::uint8_t kRegGpioDirection1 = 0x23;
constexpr std::uint8_t kRegGpioDirection2 = 0x24;
constexpr std::uint8_t kRegGpioDirection3 = 0x25;
constexpr std::uint8_t kRegGpioInterruptLevel1 = 0x26;
constexpr std::uint8_t kRegGpioInterruptLevel2 = 0x27;
constexpr std::uint8_t kRegGpioInterruptLevel3 = 0x28;
constexpr std::uint8_t kConfigKeyEventInterrupt = 0x01;

}  // namespace

bool CardputerAdvInput::write_register(
    std::uint8_t reg,
    std::uint8_t value
) {
    return M5.In_I2C.writeRegister8(kAddress, reg, value, kI2cFrequency);
}

std::uint8_t CardputerAdvInput::read_register(std::uint8_t reg) const {
    return M5.In_I2C.readRegister8(kAddress, reg, kI2cFrequency);
}

bool CardputerAdvInput::begin() {
    ready_ = false;
    physical_press_observed_ = false;
    fn_active_ = false;
    modifiers_ = 0;
    active_usages_ = {};

    bool ok = true;
    ok = write_register(kRegGpioDirection1, 0x00) && ok;
    ok = write_register(kRegGpioDirection2, 0x00) && ok;
    ok = write_register(kRegGpioDirection3, 0x00) && ok;
    ok = write_register(kRegGpiEventMode1, 0xff) && ok;
    ok = write_register(kRegGpiEventMode2, 0xff) && ok;
    ok = write_register(kRegGpiEventMode3, 0xff) && ok;
    ok = write_register(kRegGpioInterruptLevel1, 0x00) && ok;
    ok = write_register(kRegGpioInterruptLevel2, 0x00) && ok;
    ok = write_register(kRegGpioInterruptLevel3, 0x00) && ok;
    ok = write_register(kRegKeypadGpio1, 0x7f) && ok;
    ok = write_register(kRegKeypadGpio2, 0xff) && ok;
    ok = write_register(kRegKeypadGpio3, 0x00) && ok;

    for (std::size_t count = read_register(kRegEventCount) & 0x0f;
         count > 0;
         --count) {
        (void)read_register(kRegFirstEvent);
    }
    ok = write_register(kRegInterruptStatus, 0x03) && ok;
    ok = write_register(kRegConfig, kConfigKeyEventInterrupt) && ok;

    ready_ = ok;
    return ready_;
}

std::size_t CardputerAdvInput::poll(
    CardputerKeyEvent* output,
    std::size_t capacity
) {
    physical_press_observed_ = false;
    if (!ready_ || output == nullptr || capacity == 0) {
        return 0;
    }

    std::size_t emitted = 0;
    auto remaining = static_cast<std::uint8_t>(read_register(kRegEventCount) & 0x0f);
    while (remaining-- > 0) {
        const auto physical = decode_tca8418_event(read_register(kRegFirstEvent));
        if (!physical.valid) {
            continue;
        }
        const auto resolved = resolve_cardputer_key(
            physical.row,
            physical.column,
            fn_active_
        );
        if (!resolved.valid) {
            continue;
        }
        physical_press_observed_ =
            physical_press_observed_ || physical.pressed;
        if (resolved.fn_key) {
            fn_active_ = physical.pressed;
            continue;
        }
        if (resolved.modifier_bit != 0) {
            if (physical.pressed) {
                modifiers_ = static_cast<std::uint8_t>(modifiers_ | resolved.modifier_bit);
            } else {
                modifiers_ = static_cast<std::uint8_t>(modifiers_ & ~resolved.modifier_bit);
            }
            continue;
        }

        auto usage = resolved.usage;
        if (!physical.pressed) {
            const auto active = active_usages_[physical.row][physical.column];
            if (active != 0) {
                usage = active;
            }
            active_usages_[physical.row][physical.column] = 0;
        } else {
            active_usages_[physical.row][physical.column] = usage;
        }

        if (usage != 0 && emitted < capacity) {
            output[emitted++] = CardputerKeyEvent{
                physical.pressed,
                usage,
                modifiers_,
            };
        }
    }
    (void)write_register(kRegInterruptStatus, 0x01);
    return emitted;
}

}  // namespace cardbridge
