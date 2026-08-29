#pragma once

#include <cstdint>

namespace cardbridge {

constexpr std::uint8_t kHidModifierLeftControl = 0x01;
constexpr std::uint8_t kHidModifierLeftShift = 0x02;
constexpr std::uint8_t kHidModifierLeftAlt = 0x04;
constexpr std::uint8_t kHidModifierLeftGui = 0x08;

struct PhysicalKey {
    std::uint8_t row{0};
    std::uint8_t column{0};
    bool pressed{false};
    bool valid{false};
};

struct ResolvedKey {
    std::uint8_t usage{0};
    std::uint8_t modifier_bit{0};
    bool fn_key{false};
    bool valid{false};
};

PhysicalKey decode_tca8418_event(std::uint8_t raw_event);
ResolvedKey resolve_cardputer_key(
    std::uint8_t row,
    std::uint8_t column,
    bool fn_active
);

}  // namespace cardbridge
