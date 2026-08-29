cmake_minimum_required(VERSION 3.16)

option(
    CARDPUTER_LED_DIAGNOSTIC
    "Build the isolated Cardputer ADV LED diagnostic firmware"
    OFF
)

if(CARDPUTER_LED_DIAGNOSTIC)
    set(PROJECT_VER "0.9.7-led-diagnostic")
else()
    set(PROJECT_VER "0.10.0")
endif()
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
if(CARDPUTER_LED_DIAGNOSTIC)
    project(cardputer_led_diagnostic)
else()
    project(cardputer_bridge_firmware)
endif()
