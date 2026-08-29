#pragma once

#include "input_router.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace cardbridge {

constexpr std::size_t kShortcutLabelBytes = 32;
constexpr std::size_t kShortcutConfigMaximumBytes = 1800;
constexpr std::size_t kShortcutConfigMaximumChunks = 32;

struct ShortcutConfigEntry {
    std::array<std::uint8_t, 16> identifier{};
    ShortcutMapping mapping{};
    std::array<std::uint8_t, kShortcutLabelBytes> label{};
    std::uint8_t label_size{0};
};

struct ParsedShortcutConfig {
    std::uint8_t schema_version{0};
    std::uint64_t version{0};
    std::array<ShortcutConfigEntry, kMaxShortcutMappings> entries{};
    std::size_t count{0};
};

enum class ConfigCommitResult {
    kAccepted,
    kNotPrepared,
    kIncomplete,
    kHashMismatch,
    kInvalidConfig,
    kStaleVersion,
};

bool parse_shortcut_config(
    const std::uint8_t* bytes,
    std::size_t length,
    ParsedShortcutConfig& result
);

class ShortcutConfigTransaction {
public:
    bool prepare(
        std::uint64_t version,
        std::size_t total_bytes,
        std::size_t chunk_count,
        const std::uint8_t* expected_sha256
    );
    bool put_chunk(
        std::size_t index,
        std::size_t offset,
        const std::uint8_t* bytes,
        std::size_t length
    );
    ConfigCommitResult finalize(const std::uint8_t* actual_sha256);
    ConfigCommitResult validate_staging(
        const std::uint8_t* actual_sha256,
        ParsedShortcutConfig& candidate
    ) const;
    void activate_validated(const ParsedShortcutConfig& candidate);
    bool load_active(const std::uint8_t* bytes, std::size_t length);

    const ParsedShortcutConfig& active() const { return active_; }
    const std::uint8_t* staged_bytes() const { return staging_.data(); }
    std::size_t staged_size() const { return staging_size_; }
    bool staging() const { return prepared_; }

private:
    void clear_staging();

    ParsedShortcutConfig active_{};
    std::array<std::uint8_t, kShortcutConfigMaximumBytes> staging_{};
    std::array<std::uint8_t, 32> expected_sha256_{};
    std::array<std::size_t, kShortcutConfigMaximumChunks> chunk_offsets_{};
    std::array<std::size_t, kShortcutConfigMaximumChunks> chunk_lengths_{};
    std::uint64_t staging_version_{0};
    std::size_t staging_size_{0};
    std::size_t staging_chunk_count_{0};
    std::uint32_t received_chunks_{0};
    bool prepared_{false};
};

}  // namespace cardbridge
