#pragma once

#include "input_router.hpp"

#include <cstddef>
#include <cstdint>

#include <esp_err.h>

namespace cardbridge {

enum class DeviceConfigCommitResult {
    kAccepted,
    kNotPrepared,
    kIncomplete,
    kHashMismatch,
    kInvalidConfig,
    kStaleVersion,
    kStorageFailure,
};

esp_err_t device_shortcut_config_start();
bool device_shortcut_config_prepare(
    std::uint64_t version,
    std::size_t total_bytes,
    std::size_t chunk_count,
    const std::uint8_t* expected_sha256
);
bool device_shortcut_config_put_chunk(
    std::size_t index,
    std::size_t offset,
    const std::uint8_t* bytes,
    std::size_t length
);
DeviceConfigCommitResult device_shortcut_config_commit();
std::uint64_t device_shortcut_config_version();
std::uint8_t device_shortcut_config_schema_version();
std::size_t device_shortcut_config_copy_mappings(
    ShortcutMapping* output,
    std::size_t capacity
);

}  // namespace cardbridge
