#pragma once

#include <array>
#include <cstdint>

namespace cardbridge {

inline constexpr std::array<std::uint8_t, 125> kDefaultShortcutConfig{
    'C', 'B', 3, 4,
    0, 0, 0, 0, 0, 0, 0, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    1, 0, 0x14, 0x09, 0x14, 1, 4, 'Q', 'u', 'i', 't',
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
    1, 0, 0x06, 0x09, 0x06, 1, 4, 'C', 'o', 'p', 'y',
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
    1, 0, 0x2c, 0x04, 0x2c, 1, 9, 'S', 'p', 'o', 't', 'l', 'i', 'g', 'h', 't',
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4,
    1, 0, 0x10, 0x0a, 0x10, 1, 4, 'M', 'u', 't', 'e',
};

}  // namespace cardbridge
