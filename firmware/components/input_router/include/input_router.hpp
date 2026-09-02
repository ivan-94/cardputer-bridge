#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace cardbridge {

constexpr std::size_t kMaxShortcutMappings = 32;
constexpr std::uint64_t kG0ShortPressMaxMs = 350;
constexpr std::uint64_t kShortcutLearningTimeoutMs = 15000;

struct ShortcutMapping {
    bool trigger_includes_g0{true};
    std::uint8_t trigger_modifiers{0};
    std::uint8_t trigger_usage{0};
    std::uint8_t output_modifiers{0};
    std::uint8_t output_usage{0};
    bool enabled{false};
};

struct HidReport {
    std::uint8_t modifiers{0};
    std::uint8_t usage{0};
};

enum class InputActionKind {
    kG0Down,
    kG0Up,
    kKeyDown,
    kKeyUp,
    kBleAuthenticated,
    kBleDisconnected,
};

struct InputAction {
    InputActionKind kind{InputActionKind::kKeyDown};
    std::uint8_t usage{0};
    std::uint8_t modifiers{0};
    std::uint64_t at_ms{0};
};

enum class InputEffectKind {
    kHidReport,
    kToggleMicIntent,
    kShortcutFeedback,
    kNotMappedFeedback,
    kControlLinkLost,
    kShortcutLearned,
    kShortcutLearnCancelled,
};

struct InputEffect {
    InputEffectKind kind{InputEffectKind::kHidReport};
    HidReport report{};
    std::uint8_t trigger_usage{0};
    bool trigger_includes_g0{false};
    std::uint8_t trigger_modifiers{0};
    std::uint32_t learn_token{0};
};

struct InputResult {
    std::array<InputEffect, 4> effects{};
    std::size_t count{0};
};

bool should_forward_after_microphone_stop(
    bool microphone_stop_consumed,
    bool pressed
);

class InputRouter {
public:
    bool replace_mappings(const ShortcutMapping* mappings, std::size_t count);
    InputResult begin_shortcut_learning(
        std::uint32_t token,
        std::uint64_t now_ms
    );
    InputResult cancel_shortcut_learning(std::uint32_t token);
    InputResult poll_shortcut_learning(std::uint64_t now_ms);
    InputResult dispatch(const InputAction& action);
    void reset();

    bool all_keys_up() const {
        return active_report_.usage == 0 && active_report_.modifiers == 0;
    }
    bool g0_active() const { return g0_down_; }
    bool shortcut_learning() const { return shortcut_learning_; }

private:
    const ShortcutMapping* mapping_for(
        bool includes_g0,
        std::uint8_t modifiers,
        std::uint8_t usage
    ) const;
    void append_effect(
        InputResult& result,
        InputEffectKind kind,
        HidReport report = {},
        std::uint8_t trigger_usage = 0,
        bool trigger_includes_g0 = false,
        std::uint8_t trigger_modifiers = 0
    );
    void release_active_report(InputResult& result);
    void append_learning_effect(
        InputResult& result,
        InputEffectKind kind,
        bool includes_g0 = false,
        std::uint8_t modifiers = 0,
        std::uint8_t usage = 0
    );

    std::array<ShortcutMapping, kMaxShortcutMappings> mappings_{};
    std::size_t mapping_count_{0};
    bool g0_down_{false};
    bool g0_chord_consumed_{false};
    std::uint64_t g0_down_at_ms_{0};
    std::uint8_t active_physical_usage_{0};
    HidReport active_report_{};
    bool shortcut_learning_{false};
    std::uint32_t shortcut_learning_token_{0};
    std::uint64_t shortcut_learning_deadline_ms_{0};
};

}  // namespace cardbridge
