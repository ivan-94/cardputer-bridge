cmake_minimum_required(VERSION 3.16)

option(
    CARDPUTER_LED_DIAGNOSTIC
    "Build the isolated Cardputer ADV LED diagnostic firmware"
    OFF
)
set(
    CARDPUTER_BRIDGE_VERSION_OVERRIDE ""
    CACHE STRING
    "Version used only by local upgrade/rollback harness builds"
)

if(CARDPUTER_LED_DIAGNOSTIC)
    set(PROJECT_VER "0.9.7-led-diagnostic")
elseif(CARDPUTER_BRIDGE_VERSION_OVERRIDE)
    set(PROJECT_VER "${CARDPUTER_BRIDGE_VERSION_OVERRIDE}")
else()
    set(PROJECT_VER "0.10.7")
endif()
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
if(CARDPUTER_LED_DIAGNOSTIC)
    project(cardputer_led_diagnostic)
else()
    project(cardputer_bridge_firmware)
endif()
