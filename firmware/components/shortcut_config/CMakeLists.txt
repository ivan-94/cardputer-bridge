idf_component_register(
    SRCS
        "shortcut_config_core.cpp"
        "device_shortcut_config.cpp"
    INCLUDE_DIRS "include"
    REQUIRES input_router nvs_flash mbedtls
)
