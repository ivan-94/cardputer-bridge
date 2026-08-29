#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ble_bridge_command_callback_t)(
    const uint8_t *data,
    size_t length,
    void *context
);

typedef void (*ble_bridge_heartbeat_callback_t)(
    const uint8_t *data,
    size_t length,
    void *context
);

typedef struct {
    bool visible;
    bool needs_confirmation;
    uint32_t passkey;
} ble_bridge_pairing_prompt_t;

esp_err_t ble_bridge_start(
    ble_bridge_command_callback_t command_callback,
    void *command_context,
    ble_bridge_heartbeat_callback_t heartbeat_callback,
    void *heartbeat_context
);
esp_err_t ble_bridge_set_identity(const char *identity_json);
bool ble_bridge_hid_connected(void);
bool ble_bridge_control_authenticated(void);
bool ble_bridge_take_disconnect_event(void);
ble_bridge_pairing_prompt_t ble_bridge_pairing_prompt(void);
esp_err_t ble_bridge_confirm_pairing(bool accept);
esp_err_t ble_bridge_send_hid(uint8_t modifiers, uint8_t usage);
esp_err_t ble_bridge_notify_state(const char *state_json);

#ifdef __cplusplus
}
#endif
