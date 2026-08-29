idf_component_register(
    SRCS "ble_bridge.c"
    INCLUDE_DIRS "include"
    REQUIRES bt esp_hid nvs_flash
)
