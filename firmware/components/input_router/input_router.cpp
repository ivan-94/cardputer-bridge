#include "input_router.hpp"

namespace cardbridge {
namespace {

bool valid_keyboard_usage(std::uint8_t usage) {
    return usage >= 0x04 && usage <= 0xe7;
}

bool valid_trigger(const ShortcutMapping& mapping) {
    return (valid_keyboard_usage(mapping.trigger_usage) ||
            (mapping.trigger_includes_g0 && mapping.trigger_usage == 0)) &&
        (mapping.trigger_modifiers & 0xf0U) == 0;
}

bool valid_output(const ShortcutMapping& mapping) {
    return valid_keyboard_usage(mapping.output_usage) ||
        (mapping.output_usage == 0 && mapping.output_modifiers != 0);
}

}  // namespace

bool should_forward_after_microphone_stop(
    bool microphone_stop_consumed,
    bool pressed
) {
    return !microphone_stop_consumed || !pressed;
}

bool InputRouter::replace_mappings(
    const ShortcutMapping* mappings,
    std::size_t count
) {
    if (count > kMaxShortcutMappings || (count > 0 && mappings == nullptr)) {
        return false;
    }

    std::array<ShortcutMapping, kMaxShortcutMappings> candidate{};
    for (std::size_t index = 0; index < count; ++index) {
        const ShortcutMapping mapping = mappings[index];
        if (!valid_trigger(mapping) || !valid_output(mapping)) {
            return false;
        }
        for (std::size_t prior = 0; prior < index; ++prior) {
            if (candidate[prior].trigger_includes_g0 == mapping.trigger_includes_g0 &&
                candidate[prior].trigger_modifiers == mapping.trigger_modifiers &&
                candidate[prior].trigger_usage == mapping.trigger_usage) {
                return false;
            }
        }
        candidate[index] = mapping;
    }

    mappings_ = candidate;
    mapping_count_ = count;
    return true;
}

InputResult InputRouter::begin_shortcut_learning(
    std::uint32_t token,
    std::uint64_t now_ms
) {
    InputResult result;
    if (token == 0) {
        return result;
    }
    release_active_report(result);
    g0_down_ = false;
    g0_chord_consumed_ = false;
    g0_down_at_ms_ = 0;
    shortcut_learning_ = true;
    shortcut_learning_token_ = token;
    shortcut_learning_deadline_ms_ = now_ms + kShortcutLearningTimeoutMs;
    return result;
}

InputResult InputRouter::cancel_shortcut_learning(std::uint32_t token) {
    InputResult result;
    if (!shortcut_learning_ || token != shortcut_learning_token_) {
        return result;
    }
    append_learning_effect(result, InputEffectKind::kShortcutLearnCancelled);
    shortcut_learning_ = false;
    shortcut_learning_token_ = 0;
    shortcut_learning_deadline_ms_ = 0;
    g0_down_ = false;
    g0_chord_consumed_ = false;
    g0_down_at_ms_ = 0;
    return result;
}

InputResult InputRouter::poll_shortcut_learning(std::uint64_t now_ms) {
    InputResult result;
    if (shortcut_learning_ && now_ms >= shortcut_learning_deadline_ms_) {
        append_learning_effect(result, InputEffectKind::kShortcutLearnCancelled);
        shortcut_learning_ = false;
        shortcut_learning_token_ = 0;
        shortcut_learning_deadline_ms_ = 0;
        g0_down_ = false;
        g0_chord_consumed_ = false;
        g0_down_at_ms_ = 0;
    }
    return result;
}

InputResult InputRouter::dispatch(const InputAction& action) {
    InputResult result;
    switch (action.kind) {
        case InputActionKind::kG0Down:
            if (g0_down_) {
                return result;
            }
            release_active_report(result);
            g0_down_ = true;
            g0_chord_consumed_ = false;
            g0_down_at_ms_ = action.at_ms;
            return result;

        case InputActionKind::kG0Up: {
            if (!g0_down_) {
                return result;
            }
            if (shortcut_learning_) {
                append_learning_effect(
                    result,
                    InputEffectKind::kShortcutLearned,
                    true,
                    0,
                    0
                );
                shortcut_learning_ = false;
                shortcut_learning_token_ = 0;
                shortcut_learning_deadline_ms_ = 0;
                g0_down_ = false;
                g0_chord_consumed_ = false;
                g0_down_at_ms_ = 0;
                return result;
            }
            const bool clock_valid = action.at_ms >= g0_down_at_ms_;
            const std::uint64_t duration = clock_valid
                ? action.at_ms - g0_down_at_ms_
                : kG0ShortPressMaxMs + 1;
            if (!g0_chord_consumed_ && duration <= kG0ShortPressMaxMs) {
                append_effect(result, InputEffectKind::kToggleMicIntent);
                const ShortcutMapping* mapping = mapping_for(true, 0, 0);
                if (mapping != nullptr) {
                    active_report_ = HidReport{
                        mapping->output_modifiers,
                        mapping->output_usage,
                    };
                    append_effect(
                        result,
                        InputEffectKind::kHidReport,
                        active_report_
                    );
                    append_effect(
                        result,
                        InputEffectKind::kShortcutFeedback,
                        active_report_,
                        0,
                        true,
                        0
                    );
                    active_report_ = {};
                    append_effect(result, InputEffectKind::kHidReport, {});
                }
            }
            g0_down_ = false;
            g0_chord_consumed_ = false;
            g0_down_at_ms_ = 0;
            return result;
        }

        case InputActionKind::kKeyDown: {
            if (!valid_keyboard_usage(action.usage)) {
                return result;
            }
            if (shortcut_learning_) {
                append_learning_effect(
                    result,
                    InputEffectKind::kShortcutLearned,
                    g0_down_,
                    action.modifiers,
                    action.usage
                );
                shortcut_learning_ = false;
                shortcut_learning_token_ = 0;
                shortcut_learning_deadline_ms_ = 0;
                g0_down_ = false;
                g0_chord_consumed_ = false;
                g0_down_at_ms_ = 0;
                return result;
            }
            if (active_physical_usage_ == action.usage) {
                return result;
            }
            release_active_report(result);
            const ShortcutMapping* mapping = mapping_for(
                g0_down_,
                action.modifiers,
                action.usage
            );
            if (mapping != nullptr) {
                if (g0_down_) {
                    g0_chord_consumed_ = true;
                }
                active_physical_usage_ = action.usage;
                active_report_ = HidReport{
                    mapping->output_modifiers,
                    mapping->output_usage,
                };
                append_effect(
                    result,
                    InputEffectKind::kHidReport,
                    active_report_,
                    action.usage
                );
                append_effect(
                    result,
                    InputEffectKind::kShortcutFeedback,
                    active_report_,
                    action.usage,
                    g0_down_,
                    action.modifiers
                );
                return result;
            }
            if (g0_down_) {
                g0_chord_consumed_ = true;
                append_effect(
                    result,
                    InputEffectKind::kNotMappedFeedback,
                    {},
                    action.usage
                );
                return result;
            }

            active_physical_usage_ = action.usage;
            active_report_ = HidReport{action.modifiers, action.usage};
            append_effect(
                result,
                InputEffectKind::kHidReport,
                active_report_,
                action.usage
            );
            return result;
        }

        case InputActionKind::kKeyUp:
            if (shortcut_learning_) {
                return result;
            }
            if (action.usage == active_physical_usage_) {
                release_active_report(result);
            }
            return result;

        case InputActionKind::kBleAuthenticated:
            // The first report after a reconnect can race the host's HID input
            // subscription. Prime the link with an unconditional neutral
            // report so the first physical key is never the synchronization
            // packet, and clear any stale local key/chord state at the same
            // boundary.
            g0_down_ = false;
            g0_chord_consumed_ = false;
            g0_down_at_ms_ = 0;
            active_physical_usage_ = 0;
            active_report_ = {};
            append_effect(result, InputEffectKind::kHidReport, {});
            return result;

        case InputActionKind::kBleDisconnected:
            release_active_report(result);
            append_effect(result, InputEffectKind::kControlLinkLost);
            shortcut_learning_ = false;
            shortcut_learning_token_ = 0;
            shortcut_learning_deadline_ms_ = 0;
            g0_down_ = false;
            g0_chord_consumed_ = false;
            g0_down_at_ms_ = 0;
            return result;
    }
    return result;
}

void InputRouter::reset() {
    g0_down_ = false;
    g0_chord_consumed_ = false;
    g0_down_at_ms_ = 0;
    active_physical_usage_ = 0;
    active_report_ = {};
    shortcut_learning_ = false;
    shortcut_learning_token_ = 0;
    shortcut_learning_deadline_ms_ = 0;
}

const ShortcutMapping* InputRouter::mapping_for(
    bool includes_g0,
    std::uint8_t modifiers,
    std::uint8_t usage
) const {
    for (std::size_t index = 0; index < mapping_count_; ++index) {
        const ShortcutMapping& mapping = mappings_[index];
        if (mapping.enabled &&
            mapping.trigger_includes_g0 == includes_g0 &&
            mapping.trigger_modifiers == modifiers &&
            mapping.trigger_usage == usage) {
            return &mapping;
        }
    }
    return nullptr;
}

void InputRouter::append_effect(
    InputResult& result,
    InputEffectKind kind,
    HidReport report,
    std::uint8_t trigger_usage,
    bool trigger_includes_g0,
    std::uint8_t trigger_modifiers
) {
    if (result.count >= result.effects.size()) {
        return;
    }
    InputEffect effect{};
    effect.kind = kind;
    effect.report = report;
    effect.trigger_usage = trigger_usage;
    effect.trigger_includes_g0 = trigger_includes_g0;
    effect.trigger_modifiers = trigger_modifiers;
    result.effects[result.count] = effect;
    ++result.count;
}

void InputRouter::release_active_report(InputResult& result) {
    if (all_keys_up()) {
        active_physical_usage_ = 0;
        return;
    }
    active_physical_usage_ = 0;
    active_report_ = {};
    append_effect(result, InputEffectKind::kHidReport, {});
}

void InputRouter::append_learning_effect(
    InputResult& result,
    InputEffectKind kind,
    bool includes_g0,
    std::uint8_t modifiers,
    std::uint8_t usage
) {
    if (result.count >= result.effects.size()) {
        return;
    }
    InputEffect effect{};
    effect.kind = kind;
    effect.trigger_usage = usage;
    effect.trigger_includes_g0 = includes_g0;
    effect.trigger_modifiers = modifiers;
    effect.learn_token = shortcut_learning_token_;
    result.effects[result.count++] = effect;
}

}  // namespace cardbridge
