#include "shortcut_config_core.hpp"

#include <algorithm>
#include <cstring>

namespace cardbridge {
namespace {

constexpr std::size_t kHeaderBytes = 12;

bool valid_keyboard_usage(std::uint8_t usage) {
    return usage >= 0x04 && usage <= 0xe7;
}

bool valid_output(std::uint8_t modifiers, std::uint8_t usage) {
    return valid_keyboard_usage(usage) || (usage == 0 && modifiers != 0);
}

bool identifier_is_zero(const std::array<std::uint8_t, 16>& identifier) {
    return std::all_of(
        identifier.begin(),
        identifier.end(),
        [](std::uint8_t byte) { return byte == 0; }
    );
}

std::uint64_t read_u64_be(const std::uint8_t* bytes) {
    std::uint64_t value = 0;
    for (std::size_t index = 0; index < 8; ++index) {
        value = (value << 8U) | bytes[index];
    }
    return value;
}

}  // namespace

bool parse_shortcut_config(
    const std::uint8_t* bytes,
    std::size_t length,
    ParsedShortcutConfig& result
) {
    if (bytes == nullptr || length < kHeaderBytes ||
        bytes[0] != 'C' || bytes[1] != 'B' ||
        (bytes[2] != 1 && bytes[2] != 2 && bytes[2] != 3) ||
        bytes[3] > kMaxShortcutMappings) {
        return false;
    }
    const bool legacy_v1 = bytes[2] == 1;
    const bool identifiers_present = bytes[2] == 3;
    ParsedShortcutConfig parsed{};
    parsed.schema_version = bytes[2];
    parsed.count = bytes[3];
    parsed.version = read_u64_be(bytes + 4);
    if (parsed.version == 0) {
        return false;
    }

    std::size_t cursor = kHeaderBytes;
    for (std::size_t index = 0; index < parsed.count; ++index) {
        const std::size_t fixed_bytes = (legacy_v1 ? 5 : 7) +
            (identifiers_present ? 16 : 0);
        if (cursor + fixed_bytes > length) {
            return false;
        }
        ShortcutConfigEntry entry{};
        if (identifiers_present) {
            std::copy_n(bytes + cursor, entry.identifier.size(), entry.identifier.begin());
            cursor += entry.identifier.size();
            if (identifier_is_zero(entry.identifier)) {
                return false;
            }
        }
        if (legacy_v1) {
            entry.mapping.trigger_includes_g0 = true;
            entry.mapping.trigger_modifiers = 0;
            entry.mapping.trigger_usage = bytes[cursor++];
            entry.mapping.output_modifiers = bytes[cursor++];
            entry.mapping.output_usage = bytes[cursor++];
        } else {
            const std::uint8_t trigger_flags = bytes[cursor++];
            if ((trigger_flags & 0xfeU) != 0) {
                return false;
            }
            entry.mapping.trigger_includes_g0 = (trigger_flags & 0x01U) != 0;
            entry.mapping.trigger_modifiers = bytes[cursor++];
            entry.mapping.trigger_usage = bytes[cursor++];
            entry.mapping.output_modifiers = bytes[cursor++];
            entry.mapping.output_usage = bytes[cursor++];
        }
        const std::uint8_t enabled = bytes[cursor++];
        entry.label_size = bytes[cursor++];
        const bool valid_trigger =
            valid_keyboard_usage(entry.mapping.trigger_usage) ||
            (entry.mapping.trigger_includes_g0 &&
             entry.mapping.trigger_modifiers == 0 &&
             entry.mapping.trigger_usage == 0);
        if (!valid_trigger ||
            (entry.mapping.trigger_modifiers & 0xf0U) != 0 ||
            !valid_output(
                entry.mapping.output_modifiers,
                entry.mapping.output_usage
            ) ||
            enabled > 1 || entry.label_size > kShortcutLabelBytes ||
            cursor + entry.label_size > length) {
            return false;
        }
        for (std::size_t prior = 0; prior < index; ++prior) {
            if (identifiers_present &&
                parsed.entries[prior].identifier == entry.identifier) {
                return false;
            }
            const auto& prior_mapping = parsed.entries[prior].mapping;
            if (prior_mapping.trigger_includes_g0 ==
                    entry.mapping.trigger_includes_g0 &&
                prior_mapping.trigger_modifiers ==
                    entry.mapping.trigger_modifiers &&
                prior_mapping.trigger_usage == entry.mapping.trigger_usage) {
                return false;
            }
        }
        entry.mapping.enabled = enabled == 1;
        std::copy_n(bytes + cursor, entry.label_size, entry.label.begin());
        cursor += entry.label_size;
        parsed.entries[index] = entry;
    }
    if (cursor != length) {
        return false;
    }
    result = parsed;
    return true;
}

bool ShortcutConfigTransaction::prepare(
    std::uint64_t version,
    std::size_t total_bytes,
    std::size_t chunk_count,
    const std::uint8_t* expected_sha256
) {
    if (version == 0 || version <= active_.version || total_bytes < kHeaderBytes ||
        total_bytes > staging_.size() || chunk_count == 0 ||
        chunk_count > kShortcutConfigMaximumChunks || expected_sha256 == nullptr) {
        return false;
    }
    clear_staging();
    staging_version_ = version;
    staging_size_ = total_bytes;
    staging_chunk_count_ = chunk_count;
    std::copy_n(expected_sha256, expected_sha256_.size(), expected_sha256_.begin());
    prepared_ = true;
    return true;
}

bool ShortcutConfigTransaction::put_chunk(
    std::size_t index,
    std::size_t offset,
    const std::uint8_t* bytes,
    std::size_t length
) {
    if (!prepared_ || index >= staging_chunk_count_ || bytes == nullptr ||
        length == 0 || offset > staging_size_ || length > staging_size_ - offset) {
        return false;
    }
    const std::uint32_t bit = std::uint32_t{1} << index;
    if ((received_chunks_ & bit) != 0) {
        return chunk_offsets_[index] == offset &&
            chunk_lengths_[index] == length &&
            std::memcmp(staging_.data() + offset, bytes, length) == 0;
    }
    for (std::size_t prior = 0; prior < staging_chunk_count_; ++prior) {
        if ((received_chunks_ & (std::uint32_t{1} << prior)) == 0) {
            continue;
        }
        const std::size_t prior_start = chunk_offsets_[prior];
        const std::size_t prior_end = prior_start + chunk_lengths_[prior];
        if (offset < prior_end && prior_start < offset + length) {
            return false;
        }
    }
    std::copy_n(bytes, length, staging_.begin() + offset);
    chunk_offsets_[index] = offset;
    chunk_lengths_[index] = length;
    received_chunks_ |= bit;
    return true;
}

ConfigCommitResult ShortcutConfigTransaction::finalize(
    const std::uint8_t* actual_sha256
) {
    ParsedShortcutConfig parsed{};
    const ConfigCommitResult result = validate_staging(actual_sha256, parsed);
    if (result == ConfigCommitResult::kAccepted) {
        activate_validated(parsed);
    }
    return result;
}

ConfigCommitResult ShortcutConfigTransaction::validate_staging(
    const std::uint8_t* actual_sha256,
    ParsedShortcutConfig& parsed
) const {
    if (!prepared_) {
        return ConfigCommitResult::kNotPrepared;
    }
    const std::uint32_t expected_bits = staging_chunk_count_ == 32
        ? 0xffffffffU
        : (std::uint32_t{1} << staging_chunk_count_) - 1U;
    std::size_t covered = 0;
    for (std::size_t index = 0; index < staging_chunk_count_; ++index) {
        covered += chunk_lengths_[index];
    }
    if (received_chunks_ != expected_bits || covered != staging_size_) {
        return ConfigCommitResult::kIncomplete;
    }
    if (actual_sha256 == nullptr ||
        std::memcmp(actual_sha256, expected_sha256_.data(), expected_sha256_.size()) != 0) {
        return ConfigCommitResult::kHashMismatch;
    }
    if (!parse_shortcut_config(staging_.data(), staging_size_, parsed) ||
        parsed.version != staging_version_) {
        return ConfigCommitResult::kInvalidConfig;
    }
    if (parsed.version <= active_.version) {
        return ConfigCommitResult::kStaleVersion;
    }
    return ConfigCommitResult::kAccepted;
}

void ShortcutConfigTransaction::activate_validated(
    const ParsedShortcutConfig& candidate
) {
    active_ = candidate;
    clear_staging();
}

bool ShortcutConfigTransaction::load_active(
    const std::uint8_t* bytes,
    std::size_t length
) {
    ParsedShortcutConfig parsed{};
    if (!parse_shortcut_config(bytes, length, parsed)) {
        return false;
    }
    active_ = parsed;
    clear_staging();
    return true;
}

void ShortcutConfigTransaction::clear_staging() {
    std::fill(staging_.begin(), staging_.end(), 0);
    std::fill(expected_sha256_.begin(), expected_sha256_.end(), 0);
    std::fill(chunk_offsets_.begin(), chunk_offsets_.end(), 0);
    std::fill(chunk_lengths_.begin(), chunk_lengths_.end(), 0);
    staging_version_ = 0;
    staging_size_ = 0;
    staging_chunk_count_ = 0;
    received_chunks_ = 0;
    prepared_ = false;
}

}  // namespace cardbridge
