if(CARDPUTER_LED_DIAGNOSTIC)
    idf_component_register(
        SRCS "led_diagnostic_main.cpp"
        INCLUDE_DIRS "."
        REQUIRES m5stack__m5unified
    )
else()
    idf_component_register(
        SRCS "main.cpp"
        INCLUDE_DIRS "."
        REQUIRES ble_bridge bridge_domain cardputer_input control_lease control_protocol device_audio esp_driver_usb_serial_jtag firmware_update input_router recording_led serial_harness_protocol shortcut_config
    )
endif()
