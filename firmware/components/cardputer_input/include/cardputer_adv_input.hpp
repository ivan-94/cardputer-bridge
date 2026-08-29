#pragma once

#include "cardputer_keymap.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace cardbridge {

struct CardputerKeyEvent {
    bool pressed{false};
    std::uint8_t usage{0};
    std::uint8_t modifiers{0};
};

class CardputerAdvInput {
public:
    bool begin();
    std::size_t poll(CardputerKeyEvent* output, std::size_t capacity);

    bool ready() const { return ready_; }
    std::uint8_t modifiers() const { return modifiers_; }

private:
    bool write_register(std::uint8_t reg, std::uint8_t value);
    std::uint8_t read_register(std::uint8_t reg) const;

    bool ready_{false};
    bool fn_active_{false};
    std::uint8_t modifiers_{0};
    std::array<std::array<std::uint8_t, 14>, 4> active_usages_{};
};

}  // namespace cardbridge
