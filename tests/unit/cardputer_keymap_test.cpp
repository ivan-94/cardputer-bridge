#include "cardputer_keymap.hpp"

#include <cstdlib>
#include <iostream>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

std::uint8_t raw_event_for(
    std::uint8_t physical_row,
    std::uint8_t physical_column,
    bool pressed
) {
    const auto raw_row = static_cast<std::uint8_t>(physical_column / 2);
    const auto upper_half = static_cast<std::uint8_t>(physical_column % 2);
    const auto raw_column = static_cast<std::uint8_t>(physical_row + upper_half * 4);
    const auto value = static_cast<std::uint8_t>(raw_row * 10 + raw_column + 1);
    return static_cast<std::uint8_t>(value | (pressed ? 0x80 : 0x00));
}

void test_tca_event_round_trip() {
    const auto q_down = cardbridge::decode_tca8418_event(raw_event_for(1, 1, true));
    require(q_down.valid && q_down.pressed, "Q press should decode");
    require(q_down.row == 1 && q_down.column == 1, "Q coordinates should round-trip");

    const auto q_up = cardbridge::decode_tca8418_event(raw_event_for(1, 1, false));
    require(q_up.valid && !q_up.pressed, "Q release should decode");
    require(!cardbridge::decode_tca8418_event(0).valid, "zero is not a key event");
}

void test_usages_and_layers() {
    const auto q = cardbridge::resolve_cardputer_key(1, 1, false);
    require(q.valid && q.usage == 0x14, "Q should map to HID usage 0x14");

    const auto fn = cardbridge::resolve_cardputer_key(2, 0, false);
    require(fn.valid && fn.fn_key, "Fn should be tracked as a layer key");

    const auto up = cardbridge::resolve_cardputer_key(2, 11, true);
    require(up.valid && up.usage == 0x52, "Fn+semicolon should become Up");

    const auto command = cardbridge::resolve_cardputer_key(3, 2, false);
    require(command.modifier_bit == cardbridge::kHidModifierLeftGui,
            "physical Alt key should act as Command on macOS");
    const auto option = cardbridge::resolve_cardputer_key(3, 1, false);
    require(option.modifier_bit == cardbridge::kHidModifierLeftAlt,
            "physical Opt key should act as Option on macOS");
}

}  // namespace

int main() {
    test_tca_event_round_trip();
    test_usages_and_layers();
    std::cout << "PASS cardputer_tca_event_decode\n";
    std::cout << "PASS cardputer_hid_keymap_layers\n";
    return EXIT_SUCCESS;
}
