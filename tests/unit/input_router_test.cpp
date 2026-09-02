#include "input_router.hpp"

#include <array>
#include <cstdlib>
#include <iostream>

namespace {

using cardbridge::HidReport;
using cardbridge::InputAction;
using cardbridge::InputActionKind;
using cardbridge::InputEffectKind;
using cardbridge::InputRouter;
using cardbridge::ShortcutMapping;
using cardbridge::should_forward_after_microphone_stop;
using cardbridge::should_stop_microphone_for_physical_press;

constexpr std::uint8_t kUsageQ = 0x14;
constexpr std::uint8_t kUsageX = 0x1b;
constexpr std::uint8_t kLeftControlAndGui = 0x09;

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

InputAction action(
    InputActionKind kind,
    std::uint64_t at_ms,
    std::uint8_t usage = 0,
    std::uint8_t modifiers = 0
) {
    return InputAction{kind, usage, modifiers, at_ms};
}

void require_report(
    const cardbridge::InputResult& result,
    std::size_t index,
    HidReport expected,
    const char* message
) {
    require(index < result.count, message);
    require(result.effects[index].kind == InputEffectKind::kHidReport, message);
    require(result.effects[index].report.modifiers == expected.modifiers, message);
    require(result.effects[index].report.usage == expected.usage, message);
}

InputRouter configured_router() {
    InputRouter router;
    const std::array<ShortcutMapping, 1> mappings{{
        ShortcutMapping{true, 0, kUsageQ, kLeftControlAndGui, kUsageQ, true},
    }};
    require(router.replace_mappings(mappings.data(), mappings.size()),
            "valid mapping should be accepted");
    return router;
}

void test_plain_and_modified_keys_can_be_shortcut_triggers() {
    InputRouter router;
    const std::array<ShortcutMapping, 2> mappings{{
        ShortcutMapping{false, 0, kUsageQ, 0x08, kUsageX, true},
        ShortcutMapping{false, 0x01, kUsageQ, 0x09, kUsageQ, true},
    }};
    require(router.replace_mappings(mappings.data(), mappings.size()),
            "Q and Control+Q must be distinct physical triggers");

    auto plain = router.dispatch(action(InputActionKind::kKeyDown, 10, kUsageQ));
    require_report(plain, 0, HidReport{0x08, kUsageX},
                   "plain Q should invoke its configured output");
    router.dispatch(action(InputActionKind::kKeyUp, 20, kUsageQ));

    auto modified = router.dispatch(
        action(InputActionKind::kKeyDown, 30, kUsageQ, 0x01));
    require_report(modified, 0, HidReport{0x09, kUsageQ},
                   "Control+Q should invoke a different output");
    router.dispatch(action(InputActionKind::kKeyUp, 40, kUsageQ, 0x01));
}

void test_microphone_stop_preserves_the_physical_key_for_mac() {
    require(should_forward_after_microphone_stop(true, true),
            "the physical press that stops recording must still reach the Mac");
    require(should_forward_after_microphone_stop(true, false),
            "a release must still reach the router to prevent a stuck Mac key");
    require(should_forward_after_microphone_stop(false, true),
            "normal key-down must remain unchanged outside recording");
}

void test_g0_activation_transaction_cannot_immediately_stop_microphone() {
    require(!should_stop_microphone_for_physical_press(true, true, true),
            "the G0 activation transaction must not stop the microphone it opened");
    require(should_stop_microphone_for_physical_press(true, true, false),
            "a fresh physical press after activation must stop the microphone");
    require(!should_stop_microphone_for_physical_press(true, false, false),
            "a physical press cannot stop an already closed capture gate");
}

void test_g0_alone_toggles_mic_and_sends_its_bound_shortcut() {
    InputRouter router;
    const std::array<ShortcutMapping, 1> mappings{{
        ShortcutMapping{true, 0, 0, 0x08, 0x2c, true},
    }};
    require(router.replace_mappings(mappings.data(), mappings.size()),
            "G0 alone must be a valid trigger");
    router.dispatch(action(InputActionKind::kG0Down, 100));
    const auto up = router.dispatch(action(InputActionKind::kG0Up, 200));

    require(up.count == 4,
            "G0 alone should send a balanced output, expose feedback, and toggle mic");
    require_report(up, 0, HidReport{0x08, 0x2c},
                   "G0 alone should send its configured Mac shortcut before recording");
    require(up.effects[1].kind == InputEffectKind::kShortcutFeedback,
            "G0 alone mapping should expose shortcut feedback");
    require(up.effects[1].trigger_includes_g0 &&
            up.effects[1].trigger_modifiers == 0 &&
            up.effects[1].trigger_usage == 0,
            "G0-alone feedback must preserve the physical trigger");
    require_report(up, 2, HidReport{0, 0},
                   "G0-alone shortcut must release HID before recording starts");
    require(up.effects[3].kind == InputEffectKind::kToggleMicIntent,
            "G0 alone must open the microphone only after shortcut release");
}

void test_g0_that_stops_recording_sends_shortcut_without_reopening_mic() {
    InputRouter router;
    const std::array<ShortcutMapping, 1> mappings{{
        ShortcutMapping{true, 0, 0, 0x08, 0x2c, true},
    }};
    require(router.replace_mappings(mappings.data(), mappings.size()),
            "G0 alone must be a valid trigger");
    router.dispatch(action(InputActionKind::kG0Down, 100));
    const auto up = router.dispatch(
        action(InputActionKind::kG0UpShortcutOnly, 200));

    require(up.count == 3,
            "G0 used to stop recording should only send its mapped shortcut");
    require_report(up, 0, HidReport{0x08, 0x2c},
                   "recording-stop G0 should still reach the Mac");
    require(up.effects[1].kind == InputEffectKind::kShortcutFeedback,
            "recording-stop G0 should expose shortcut feedback");
    require_report(up, 2, HidReport{0, 0},
                   "recording-stop G0 should release its Mac shortcut");
}

void test_modifier_only_output_is_valid_and_balanced() {
    InputRouter router;
    const std::array<ShortcutMapping, 1> mappings{{
        ShortcutMapping{false, 0, kUsageQ, 0x88, 0, true},
    }};
    require(router.replace_mappings(mappings.data(), mappings.size()),
            "left+right command without a primary key must be a valid output");

    const auto down = router.dispatch(
        action(InputActionKind::kKeyDown, 10, kUsageQ));
    require_report(down, 0, HidReport{0x88, 0},
                   "modifier-only output must preserve both command sides");
    const auto up = router.dispatch(
        action(InputActionKind::kKeyUp, 20, kUsageQ));
    require_report(up, 0, HidReport{0, 0},
                   "modifier-only output must still release all modifiers");

    const std::array<ShortcutMapping, 1> empty{{
        ShortcutMapping{false, 0, kUsageQ, 0, 0, true},
    }};
    require(!router.replace_mappings(empty.data(), empty.size()),
            "an output with neither modifiers nor primary key must be rejected");
}

void test_learning_accepts_only_cardputer_physical_input() {
    InputRouter router = configured_router();
    const auto started = router.begin_shortcut_learning(0x12345678U, 100);
    require(started.count == 0, "idle router should start learning without HID");

    router.dispatch(action(InputActionKind::kG0Down, 120));
    const auto captured = router.dispatch(
        action(InputActionKind::kKeyDown, 140, kUsageQ, 0x01));
    require(captured.count == 1,
            "physical G0+Control+Q should produce one learn event");
    require(captured.effects[0].kind == InputEffectKind::kShortcutLearned &&
            captured.effects[0].learn_token == 0x12345678U &&
            captured.effects[0].trigger_includes_g0 &&
            captured.effects[0].trigger_modifiers == 0x01 &&
            captured.effects[0].trigger_usage == kUsageQ,
            "learn event must preserve the complete physical chord and token");
    require(router.all_keys_up(), "learning must suppress ordinary HID output");
}

void test_learning_can_capture_g0_alone_without_toggling_mic() {
    InputRouter router = configured_router();
    router.begin_shortcut_learning(7, 100);
    router.dispatch(action(InputActionKind::kG0Down, 120));
    const auto captured = router.dispatch(action(InputActionKind::kG0Up, 180));
    require(captured.count == 1,
            "G0 release should capture G0 alone during learning");
    require(captured.effects[0].kind == InputEffectKind::kShortcutLearned &&
            captured.effects[0].trigger_includes_g0 &&
            captured.effects[0].trigger_usage == 0,
            "G0-alone learn event must not invent a primary key");
}

void test_plain_key_has_balanced_reports() {
    InputRouter router = configured_router();
    auto down = router.dispatch(action(InputActionKind::kKeyDown, 10, kUsageQ));
    require_report(down, 0, HidReport{0, kUsageQ},
                   "plain Q down should become a HID report");

    auto up = router.dispatch(action(InputActionKind::kKeyUp, 20, kUsageQ));
    require_report(up, 0, HidReport{0, 0},
                   "plain Q up should release every key");
    require(router.all_keys_up(), "plain key path must end all-keys-up");
}

void test_authenticated_link_starts_with_a_neutral_report() {
    InputRouter router = configured_router();
    auto synchronized = router.dispatch(
        action(InputActionKind::kBleAuthenticated, 10));

    require(synchronized.count == 1,
            "authenticated HID link should emit one synchronization report");
    require_report(synchronized, 0, HidReport{0, 0},
                   "authenticated HID link should start all-keys-up");
    require(router.all_keys_up(),
            "authenticated HID link must start with clean local key state");
}

void test_g0_short_press_toggles_without_hid() {
    InputRouter router = configured_router();
    require(router.dispatch(action(InputActionKind::kG0Down, 100)).count == 0,
            "G0 down should wait for a chord");
    auto up = router.dispatch(action(InputActionKind::kG0Up, 300));
    require(up.count == 1, "short G0 should emit one domain effect");
    require(up.effects[0].kind == InputEffectKind::kToggleMicIntent,
            "short G0 should toggle mic intent");
    require(router.all_keys_up(), "G0 itself must never become a HID key");
}

void test_g0_mapped_chord_and_release() {
    InputRouter router = configured_router();
    router.dispatch(action(InputActionKind::kG0Down, 100));
    auto down = router.dispatch(action(InputActionKind::kKeyDown, 180, kUsageQ));
    require_report(down, 0, HidReport{kLeftControlAndGui, kUsageQ},
                   "G0+Q should send control+command+Q");
    require(down.count == 2, "mapped chord should also expose shortcut feedback");
    require(down.effects[1].kind == InputEffectKind::kShortcutFeedback,
            "mapped chord should expose shortcut feedback");
    require(down.effects[1].trigger_includes_g0 &&
            down.effects[1].trigger_modifiers == 0 &&
            down.effects[1].trigger_usage == kUsageQ,
            "mapped feedback must preserve the complete physical trigger");

    auto key_up = router.dispatch(action(InputActionKind::kKeyUp, 220, kUsageQ));
    require_report(key_up, 0, HidReport{0, 0},
                   "mapped key up should release modifiers and usage");
    auto g0_up = router.dispatch(action(InputActionKind::kG0Up, 240));
    require(g0_up.count == 0, "G0 release after chord must not toggle mic");
    require(router.all_keys_up(), "mapped chord must end all-keys-up");
}

void test_unmapped_chord_is_consumed() {
    InputRouter router = configured_router();
    router.dispatch(action(InputActionKind::kG0Down, 100));
    auto down = router.dispatch(action(InputActionKind::kKeyDown, 150, kUsageX));
    require(down.count == 1, "unmapped chord should produce one feedback effect");
    require(down.effects[0].kind == InputEffectKind::kNotMappedFeedback,
            "unmapped chord should be visible without typing");
    require(router.dispatch(action(InputActionKind::kKeyUp, 180, kUsageX)).count == 0,
            "unmapped key up should not emit HID");
    require(router.dispatch(action(InputActionKind::kG0Up, 200)).count == 0,
            "unmapped chord must suppress short-press mic toggle");
    require(router.all_keys_up(), "unmapped chord must not leak a HID key");
}

void test_long_g0_and_disconnect_fail_closed() {
    InputRouter router = configured_router();
    router.dispatch(action(InputActionKind::kG0Down, 100));
    require(router.dispatch(action(InputActionKind::kG0Up, 1000)).count == 0,
            "long G0 must do nothing");

    router.dispatch(action(InputActionKind::kKeyDown, 1100, kUsageQ, 0x02));
    auto disconnected = router.dispatch(
        action(InputActionKind::kBleDisconnected, 1110));
    require(disconnected.count == 2,
            "disconnect should release HID and notify the domain");
    require_report(disconnected, 0, HidReport{0, 0},
                   "disconnect should force all-keys-up");
    require(disconnected.effects[1].kind == InputEffectKind::kControlLinkLost,
            "disconnect should force the fail-closed domain path");
    require(router.all_keys_up(), "disconnect must clear local key state");
}

void test_mapping_replacement_is_atomic() {
    InputRouter router = configured_router();
    std::array<ShortcutMapping, cardbridge::kMaxShortcutMappings + 1> too_many{};
    require(!router.replace_mappings(too_many.data(), too_many.size()),
            "too many mappings should be rejected");

    router.dispatch(action(InputActionKind::kG0Down, 0));
    auto result = router.dispatch(action(InputActionKind::kKeyDown, 1, kUsageQ));
    require_report(result, 0, HidReport{kLeftControlAndGui, kUsageQ},
                   "invalid replacement must preserve last-known-good mappings");
}

}  // namespace

int main() {
    test_plain_key_has_balanced_reports();
    test_microphone_stop_preserves_the_physical_key_for_mac();
    test_g0_activation_transaction_cannot_immediately_stop_microphone();
    test_plain_and_modified_keys_can_be_shortcut_triggers();
    test_g0_alone_toggles_mic_and_sends_its_bound_shortcut();
    test_g0_that_stops_recording_sends_shortcut_without_reopening_mic();
    test_modifier_only_output_is_valid_and_balanced();
    test_learning_accepts_only_cardputer_physical_input();
    test_learning_can_capture_g0_alone_without_toggling_mic();
    test_authenticated_link_starts_with_a_neutral_report();
    test_g0_short_press_toggles_without_hid();
    test_g0_mapped_chord_and_release();
    test_unmapped_chord_is_consumed();
    test_long_g0_and_disconnect_fail_closed();
    test_mapping_replacement_is_atomic();
    std::cout << "PASS input_router_plain_key_balanced\n";
    std::cout << "PASS input_router_authenticated_link_neutral_sync\n";
    std::cout << "PASS input_router_g0_short_chord_unmapped_long\n";
    std::cout << "PASS input_router_disconnect_all_keys_up\n";
    std::cout << "PASS input_router_mapping_atomicity\n";
    return EXIT_SUCCESS;
}
