idf_component_register(
    SRCS
        "firmware_update.cpp"
        "firmware_update_policy.cpp"
    INCLUDE_DIRS "include"
    REQUIRES app_update control_protocol esp_http_client esp_https_ota esp-tls esp_wifi mbedtls
)
