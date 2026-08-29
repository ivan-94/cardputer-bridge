#include "device_shortcut_config.hpp"

#include "default_shortcut_config.hpp"
#include "shortcut_config_core.hpp"

#include <nvs.h>
#include <psa/crypto.h>

#include <algorithm>
#include <array>

namespace cardbridge {
namespace {

constexpr char kNamespace[] = "bridge_cfg";
constexpr char kActiveKey[] = "active";

ShortcutConfigTransaction s_transaction;
ParsedShortcutConfig s_commit_candidate;
nvs_handle_t s_nvs = 0;

DeviceConfigCommitResult translate(ConfigCommitResult result) {
    switch (result) {
        case ConfigCommitResult::kAccepted:
            return DeviceConfigCommitResult::kAccepted;
        case ConfigCommitResult::kNotPrepared:
            return DeviceConfigCommitResult::kNotPrepared;
        case ConfigCommitResult::kIncomplete:
            return DeviceConfigCommitResult::kIncomplete;
        case ConfigCommitResult::kHashMismatch:
            return DeviceConfigCommitResult::kHashMismatch;
        case ConfigCommitResult::kInvalidConfig:
            return DeviceConfigCommitResult::kInvalidConfig;
        case ConfigCommitResult::kStaleVersion:
            return DeviceConfigCommitResult::kStaleVersion;
    }
    return DeviceConfigCommitResult::kInvalidConfig;
}

}  // namespace

esp_err_t device_shortcut_config_start() {
    if (!s_transaction.load_active(
            kDefaultShortcutConfig.data(),
            kDefaultShortcutConfig.size()
        )) {
        return ESP_ERR_INVALID_STATE;
    }
    esp_err_t result = nvs_open(kNamespace, NVS_READWRITE, &s_nvs);
    if (result != ESP_OK) {
        return result;
    }
    std::array<std::uint8_t, kShortcutConfigMaximumBytes> persisted{};
    std::size_t persisted_size = persisted.size();
    result = nvs_get_blob(s_nvs, kActiveKey, persisted.data(), &persisted_size);
    if (result == ESP_ERR_NVS_NOT_FOUND) {
        return ESP_OK;
    }
    if (result != ESP_OK) {
        return result;
    }
    return s_transaction.load_active(persisted.data(), persisted_size)
        ? ESP_OK
        : ESP_ERR_INVALID_CRC;
}

bool device_shortcut_config_prepare(
    std::uint64_t version,
    std::size_t total_bytes,
    std::size_t chunk_count,
    const std::uint8_t* expected_sha256
) {
    return s_transaction.prepare(
        version,
        total_bytes,
        chunk_count,
        expected_sha256
    );
}

bool device_shortcut_config_put_chunk(
    std::size_t index,
    std::size_t offset,
    const std::uint8_t* bytes,
    std::size_t length
) {
    return s_transaction.put_chunk(index, offset, bytes, length);
}

DeviceConfigCommitResult device_shortcut_config_commit() {
    if (!s_transaction.staging()) {
        return DeviceConfigCommitResult::kNotPrepared;
    }
    std::array<std::uint8_t, 32> digest{};
    std::size_t digest_size = 0;
    if (psa_crypto_init() != PSA_SUCCESS ||
        psa_hash_compute(
            PSA_ALG_SHA_256,
            s_transaction.staged_bytes(),
            s_transaction.staged_size(),
            digest.data(),
            digest.size(),
            &digest_size
        ) != PSA_SUCCESS || digest_size != digest.size()) {
        return DeviceConfigCommitResult::kStorageFailure;
    }

    const auto staged_size = s_transaction.staged_size();
    const ConfigCommitResult validation = s_transaction.validate_staging(
        digest.data(),
        s_commit_candidate
    );
    if (validation != ConfigCommitResult::kAccepted) {
        return translate(validation);
    }
    if (s_nvs == 0 ||
        nvs_set_blob(
            s_nvs,
            kActiveKey,
            s_transaction.staged_bytes(),
            staged_size
        ) != ESP_OK ||
        nvs_commit(s_nvs) != ESP_OK) {
        return DeviceConfigCommitResult::kStorageFailure;
    }
    s_transaction.activate_validated(s_commit_candidate);
    return DeviceConfigCommitResult::kAccepted;
}

std::uint64_t device_shortcut_config_version() {
    return s_transaction.active().version;
}

std::uint8_t device_shortcut_config_schema_version() {
    return s_transaction.active().schema_version;
}

std::size_t device_shortcut_config_copy_mappings(
    ShortcutMapping* output,
    std::size_t capacity
) {
    const auto& active = s_transaction.active();
    if (output == nullptr || capacity < active.count) {
        return 0;
    }
    for (std::size_t index = 0; index < active.count; ++index) {
        output[index] = active.entries[index].mapping;
    }
    return active.count;
}

}  // namespace cardbridge
