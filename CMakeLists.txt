cmake_minimum_required(VERSION 3.20)

project(cardputer_bridge_host LANGUAGES CXX)

enable_testing()

find_package(Python3 REQUIRED COMPONENTS Interpreter)

add_library(bridge_domain
    firmware/components/bridge_domain/bridge_domain.cpp
)

target_include_directories(bridge_domain
    PUBLIC firmware/components/bridge_domain/include
)

target_compile_features(bridge_domain PUBLIC cxx_std_17)
target_compile_options(bridge_domain PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(bridge_domain_test
    tests/unit/bridge_domain_test.cpp
)

target_link_libraries(bridge_domain_test PRIVATE bridge_domain)
target_compile_options(bridge_domain_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME bridge_domain_test COMMAND bridge_domain_test)

add_library(recording_led
    firmware/components/recording_led/recording_led.cpp
)

target_include_directories(recording_led
    PUBLIC firmware/components/recording_led/include
)

target_compile_features(recording_led PUBLIC cxx_std_17)
target_compile_options(recording_led PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(recording_led_test
    tests/unit/recording_led_test.cpp
)

target_link_libraries(recording_led_test PRIVATE recording_led)
target_compile_options(recording_led_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME recording_led_test COMMAND recording_led_test)

add_library(control_lease
    firmware/components/control_lease/control_lease.cpp
)

target_include_directories(control_lease
    PUBLIC firmware/components/control_lease/include
)

target_link_libraries(control_lease PUBLIC bridge_domain)
target_compile_features(control_lease PUBLIC cxx_std_17)
target_compile_options(control_lease PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(control_lease_test
    tests/unit/control_lease_test.cpp
)

target_link_libraries(control_lease_test PRIVATE control_lease bridge_domain)
target_compile_options(control_lease_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME control_lease_test COMMAND control_lease_test)

add_library(input_router
    firmware/components/input_router/input_router.cpp
)

target_include_directories(input_router
    PUBLIC firmware/components/input_router/include
)

target_compile_features(input_router PUBLIC cxx_std_17)
target_compile_options(input_router PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(input_router_test
    tests/unit/input_router_test.cpp
)

target_link_libraries(input_router_test PRIVATE input_router)
target_compile_options(input_router_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME input_router_test COMMAND input_router_test)

add_library(shortcut_config_core
    firmware/components/shortcut_config/shortcut_config_core.cpp
)

target_include_directories(shortcut_config_core
    PUBLIC
        firmware/components/shortcut_config/include
        firmware/components/input_router/include
)

target_compile_features(shortcut_config_core PUBLIC cxx_std_17)
target_compile_options(shortcut_config_core PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(shortcut_config_core_test
    tests/unit/shortcut_config_core_test.cpp
)

target_link_libraries(shortcut_config_core_test PRIVATE shortcut_config_core input_router)
target_compile_options(shortcut_config_core_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME shortcut_config_core_test COMMAND shortcut_config_core_test)

add_library(cardputer_keymap
    firmware/components/cardputer_input/cardputer_keymap.cpp
)

target_include_directories(cardputer_keymap
    PUBLIC firmware/components/cardputer_input/include
)

target_compile_features(cardputer_keymap PUBLIC cxx_std_17)
target_compile_options(cardputer_keymap PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(cardputer_keymap_test
    tests/unit/cardputer_keymap_test.cpp
)

target_link_libraries(cardputer_keymap_test PRIVATE cardputer_keymap)
target_compile_options(cardputer_keymap_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME cardputer_keymap_test COMMAND cardputer_keymap_test)

add_library(control_protocol
    firmware/components/control_protocol/control_protocol.cpp
)

target_include_directories(control_protocol
    PUBLIC firmware/components/control_protocol/include
)

target_compile_features(control_protocol PUBLIC cxx_std_17)
target_compile_options(control_protocol PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(control_protocol_test
    tests/unit/control_protocol_test.cpp
)

target_link_libraries(control_protocol_test PRIVATE control_protocol)
target_compile_options(control_protocol_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME control_protocol_test COMMAND control_protocol_test)

add_library(serial_harness_protocol
    firmware/components/serial_harness_protocol/serial_harness_protocol.cpp
)

target_include_directories(serial_harness_protocol
    PUBLIC firmware/components/serial_harness_protocol/include
)

target_compile_features(serial_harness_protocol PUBLIC cxx_std_17)
target_compile_options(serial_harness_protocol PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(serial_harness_protocol_test
    tests/unit/serial_harness_protocol_test.cpp
)

target_link_libraries(serial_harness_protocol_test PRIVATE serial_harness_protocol)
target_compile_options(serial_harness_protocol_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME serial_harness_protocol_test COMMAND serial_harness_protocol_test)

add_library(audio_packet
    firmware/components/audio_transport/audio_packet.cpp
)

target_include_directories(audio_packet
    PUBLIC firmware/components/audio_transport/include
)

target_compile_features(audio_packet PUBLIC cxx_std_17)
target_compile_options(audio_packet PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(audio_packet_test
    tests/unit/audio_packet_test.cpp
)

target_link_libraries(audio_packet_test PRIVATE audio_packet)
target_compile_options(audio_packet_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME audio_packet_test COMMAND audio_packet_test)

add_library(firmware_update_policy
    firmware/components/firmware_update/firmware_update_policy.cpp
)

target_include_directories(firmware_update_policy
    PUBLIC firmware/components/firmware_update/include
)

target_compile_features(firmware_update_policy PUBLIC cxx_std_17)
target_compile_options(firmware_update_policy PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(firmware_update_policy_test
    tests/unit/firmware_update_policy_test.cpp
)

target_link_libraries(firmware_update_policy_test PRIVATE firmware_update_policy)
target_compile_options(firmware_update_policy_test PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(NAME firmware_update_policy_test COMMAND firmware_update_policy_test)

add_executable(input_router_host
    harness/fake-device/input_router_host.cpp
)

target_link_libraries(input_router_host PRIVATE input_router)
target_compile_options(input_router_host PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(
    NAME input_router_host_verifier
    COMMAND ${Python3_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/integration/verify_input_router_scenario.py
        $<TARGET_FILE:input_router_host>
)
set_tests_properties(
    input_router_host_verifier
    PROPERTIES ENVIRONMENT "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}"
)

add_executable(bridge_domain_host
    harness/fake-device/bridge_domain_host.cpp
)

target_link_libraries(bridge_domain_host PRIVATE bridge_domain)
target_compile_options(bridge_domain_host PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_test(
    NAME bridge_domain_host_verifier
    COMMAND ${Python3_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/integration/verify_host_scenario.py
        $<TARGET_FILE:bridge_domain_host>
)
set_tests_properties(
    bridge_domain_host_verifier
    PROPERTIES ENVIRONMENT "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}"
)
