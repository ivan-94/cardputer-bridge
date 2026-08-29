#include "default_shortcut_config.hpp"
#include "shortcut_config_core.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <iostream>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

std::array<std::uint8_t, 60> two_mapping_config() {
    return {
        'C', 'B', 3, 2,
        0, 0, 0, 0, 0, 0, 0, 7,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
        1, 0, 0x14, 0x09, 0x14, 1, 2, 'Q', 'Q',
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
        0, 1, 0x06, 0x09, 0x06, 0, 0,
    };
}

std::array<std::uint8_t, 28> v2_two_mapping_config() {
    return {
        'C', 'B', 2, 2,
        0, 0, 0, 0, 0, 0, 0, 7,
        1, 0, 0x14, 0x09, 0x14, 1, 2, 'Q', 'Q',
        0, 1, 0x06, 0x09, 0x06, 0, 0,
    };
}

std::array<std::uint8_t, 24> legacy_two_mapping_config() {
    return {
        'C', 'B', 1, 2,
        0, 0, 0, 0, 0, 0, 0, 7,
        0x14, 0x09, 0x14, 1, 2, 'Q', 'Q',
        0x06, 0x09, 0x06, 0, 0,
    };
}

void test_parse_canonical_config() {
    const auto bytes = two_mapping_config();
    cardbridge::ParsedShortcutConfig parsed{};
    require(cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "valid canonical config should parse");
    require(parsed.schema_version == 3 && parsed.version == 7 && parsed.count == 2,
            "schema, version and mapping count should survive parsing");
    require(parsed.entries[0].identifier[15] == 1 &&
            parsed.entries[1].identifier[15] == 2,
            "schema v3 identifiers should survive parsing");
    require(parsed.entries[0].mapping.trigger_includes_g0 &&
            parsed.entries[0].mapping.trigger_modifiers == 0 &&
            parsed.entries[0].mapping.trigger_usage == 0x14 &&
            parsed.entries[0].mapping.output_modifiers == 0x09 &&
            parsed.entries[0].label_size == 2 &&
            std::memcmp(parsed.entries[0].label.data(), "QQ", 2) == 0,
            "first mapping should preserve HID values and label");
}

void test_factory_default_is_schema_v3_and_parseable() {
    cardbridge::ParsedShortcutConfig parsed{};
    require(cardbridge::parse_shortcut_config(
                cardbridge::kDefaultShortcutConfig.data(),
                cardbridge::kDefaultShortcutConfig.size(),
                parsed
            ),
            "factory default should be a parseable canonical config");
    require(parsed.schema_version == 3 && parsed.version == 1 && parsed.count == 4,
            "factory default should stay below the Mac bootstrap version");
    for (std::size_t index = 0; index < parsed.count; ++index) {
        require(parsed.entries[index].identifier[15] == index + 1,
                "factory default mappings should have stable nonzero identifiers");
    }
}

void test_parse_v2_config_without_identifiers() {
    const auto bytes = v2_two_mapping_config();
    cardbridge::ParsedShortcutConfig parsed{};
    require(cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "schema v2 config should remain readable");
    require(parsed.schema_version == 2 &&
            parsed.entries[0].mapping.trigger_usage == 0x14,
            "schema v2 trigger should survive parsing");
}

void test_parse_legacy_config_as_implicit_g0_chords() {
    const auto bytes = legacy_two_mapping_config();
    cardbridge::ParsedShortcutConfig parsed{};
    require(cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "legacy canonical config should remain readable");
    require(parsed.schema_version == 1 &&
            parsed.entries[0].mapping.trigger_includes_g0 &&
            parsed.entries[0].mapping.trigger_modifiers == 0 &&
            parsed.entries[0].mapping.trigger_usage == 0x14,
            "legacy trigger should migrate to implicit G0+key");
}

void test_transaction_is_complete_atomic_and_hash_bound() {
    const auto bytes = two_mapping_config();
    std::array<std::uint8_t, 32> expected_hash{};
    expected_hash[0] = 0x42;
    cardbridge::ShortcutConfigTransaction transaction;
    require(transaction.prepare(7, bytes.size(), 2, expected_hash.data()),
            "valid prepare should start staging");
    require(transaction.put_chunk(1, 12, bytes.data() + 12, bytes.size() - 12),
            "out-of-order second chunk should stage");
    require(transaction.finalize(expected_hash.data()) ==
                cardbridge::ConfigCommitResult::kIncomplete,
            "incomplete staging must never replace active config");
    require(transaction.put_chunk(0, 0, bytes.data(), 12),
            "first chunk should complete staging");
    auto wrong_hash = expected_hash;
    wrong_hash[0] ^= 0xff;
    require(transaction.finalize(wrong_hash.data()) ==
                cardbridge::ConfigCommitResult::kHashMismatch,
            "hash mismatch must preserve last-known-good");
    require(transaction.finalize(expected_hash.data()) ==
                cardbridge::ConfigCommitResult::kAccepted,
            "complete hash-bound staging should commit");
    require(transaction.active().version == 7 &&
            transaction.active().count == 2,
            "accepted commit should atomically publish parsed mappings");
}

void test_invalid_config_cannot_replace_active() {
    auto bytes = two_mapping_config();
    bytes[53] = 1;
    bytes[54] = 0;
    bytes[55] = 0x14;
    cardbridge::ParsedShortcutConfig parsed{};
    require(!cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "duplicate trigger usage should be rejected");
    bytes = two_mapping_config();
    bytes[34] = 33;
    require(!cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "label over 32 bytes should be rejected before reading past input");

    bytes = two_mapping_config();
    std::copy_n(bytes.data() + 12, 16, bytes.data() + 37);
    require(!cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "duplicate mapping identifiers should be rejected");

    bytes = two_mapping_config();
    bytes[28] = 1;
    bytes[29] = 1;
    bytes[30] = 0;
    require(!cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "G0 plus modifiers without a primary key should be rejected");
}

void test_modifier_only_output_is_valid_but_empty_output_is_not() {
    auto bytes = two_mapping_config();
    bytes[31] = 0x88;
    bytes[32] = 0;
    cardbridge::ParsedShortcutConfig parsed{};
    require(cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "canonical config should accept left+right command without a primary key");
    require(parsed.entries[0].mapping.output_modifiers == 0x88 &&
            parsed.entries[0].mapping.output_usage == 0,
            "modifier-only output must preserve the full HID modifier byte");

    bytes[31] = 0;
    require(!cardbridge::parse_shortcut_config(bytes.data(), bytes.size(), parsed),
            "canonical config must reject an entirely empty output");
}

void test_validation_does_not_publish_before_storage_commit() {
    const auto bytes = two_mapping_config();
    std::array<std::uint8_t, 32> hash{};
    hash[0] = 0x77;
    cardbridge::ShortcutConfigTransaction transaction;
    require(transaction.prepare(7, bytes.size(), 1, hash.data()),
            "prepare should accept candidate");
    require(transaction.put_chunk(0, 0, bytes.data(), bytes.size()),
            "complete candidate should stage");
    cardbridge::ParsedShortcutConfig candidate{};
    require(transaction.validate_staging(hash.data(), candidate) ==
                cardbridge::ConfigCommitResult::kAccepted,
            "candidate should validate without publication");
    require(transaction.active().version == 0 && transaction.staging(),
            "validation must preserve last-known-good until storage commits");
    transaction.activate_validated(candidate);
    require(transaction.active().version == 7 && !transaction.staging(),
            "activation should publish only the validated candidate");
}

}  // namespace

int main() {
    test_parse_canonical_config();
    test_factory_default_is_schema_v3_and_parseable();
    test_parse_v2_config_without_identifiers();
    test_parse_legacy_config_as_implicit_g0_chords();
    test_transaction_is_complete_atomic_and_hash_bound();
    test_invalid_config_cannot_replace_active();
    test_modifier_only_output_is_valid_but_empty_output_is_not();
    test_validation_does_not_publish_before_storage_commit();
    std::cout << "PASS shortcut_config_canonical_atomic_hash_bound\n";
    return EXIT_SUCCESS;
}
