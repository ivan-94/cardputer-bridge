idf_component_register(
    SRCS "device_audio.cpp"
    INCLUDE_DIRS "include"
    REQUIRES audio_transport control_protocol esp_event esp_netif esp_wifi lwip mbedtls m5stack__m5unified
)
