#include "cardputer_keymap.hpp"

#include <array>
#include <cstddef>

namespace cardbridge {
namespace {

constexpr std::uint8_t kFnSentinel = 0xff;
constexpr std::uint8_t kModifierSentinel = 0xfe;

// Physical layout from M5Stack's M5Cardputer library. Values are USB HID
// keyboard usages, not ASCII characters.
constexpr std::array<std::array<std::uint8_t, 14>, 4> kBaseUsage{{
    {{0x35, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23,
      0x24, 0x25, 0x26, 0x27, 0x2d, 0x2e, 0x2a}},
    {{0x2b, 0x14, 0x1a, 0x08, 0x15, 0x17, 0x1c,
      0x18, 0x0c, 0x12, 0x13, 0x2f, 0x30, 0x31}},
    {{kFnSentinel, kModifierSentinel, 0x04, 0x16, 0x07, 0x09, 0x0a,
      0x0b, 0x0d, 0x0e, 0x0f, 0x33, 0x34, 0x28}},
    {{kModifierSentinel, kModifierSentinel, kModifierSentinel, 0x1d, 0x1b,
      0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0x2c}},
}};

constexpr std::array<std::array<std::uint8_t, 14>, 4> kFnUsage{{
    {{0x29, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f,
      0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x4c}},
    {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
    {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x52, 0, 0}},
    {{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x50, 0x51, 0x4f, 0}},
}};

std::uint8_t modifier_for(std::uint8_t row, std::uint8_t column) {
    if (row == 2 && column == 1) {
        return kHidModifierLeftShift;
    }
    if (row == 3 && column == 0) {
        return kHidModifierLeftControl;
    }
    if (row == 3 && column == 1) {
        return kHidModifierLeftAlt;
    }
    if (row == 3 && column == 2) {
        return kHidModifierLeftGui;
    }
    return 0;
}

}  // namespace

PhysicalKey decode_tca8418_event(std::uint8_t raw_event) {
    PhysicalKey result{};
    const auto value = static_cast<std::uint8_t>(raw_event & 0x7f);
    if (value == 0) {
        return result;
    }

    const auto zero_based = static_cast<std::uint8_t>(value - 1);
    const auto raw_row = static_cast<std::uint8_t>(zero_based / 10);
    const auto raw_column = static_cast<std::uint8_t>(zero_based % 10);
    const auto row = static_cast<std::uint8_t>((raw_column + 4) % 4);
    const auto column = static_cast<std::uint8_t>(
        raw_row * 2 + (raw_column > 3 ? 1 : 0)
    );
    if (row >= 4 || column >= 14) {
        return result;
    }

    result.row = row;
    result.column = column;
    result.pressed = (raw_event & 0x80) != 0;
    result.valid = true;
    return result;
}

ResolvedKey resolve_cardputer_key(
    std::uint8_t row,
    std::uint8_t column,
    bool fn_active
) {
    if (row >= kBaseUsage.size() || column >= kBaseUsage[row].size()) {
        return {};
    }

    const auto base = kBaseUsage[row][column];
    if (base == kFnSentinel) {
        return ResolvedKey{0, 0, true, true};
    }
    if (base == kModifierSentinel) {
        return ResolvedKey{0, modifier_for(row, column), false, true};
    }
    if (fn_active && kFnUsage[row][column] != 0) {
        return ResolvedKey{kFnUsage[row][column], 0, false, true};
    }
    return ResolvedKey{base, 0, false, true};
}

}  // namespace cardbridge
