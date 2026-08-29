/*
 * SPDX-License-Identifier: MIT
 *
 * The BLE HID report descriptor and Bluedroid setup sequence are adapted from
 * Espressif's esp_hid_device example (CC0-1.0 OR Unlicense). The vendor GATT
 * service is Cardputer Bridge code and deliberately requires encrypted,
 * MITM-authenticated access for every application value.
 */

#include "ble_bridge.h"

#include <inttypes.h>
#include <string.h>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatt_common_api.h"
#include "esp_gatts_api.h"
#include "esp_hid_common.h"
#include "esp_hidd.h"
#include "esp_hidd_gatts.h"
#include "esp_log.h"
#include "nvs_flash.h"

static const char *TAG = "ble_bridge";

#define VENDOR_APP_ID 0x4342
#define VENDOR_SERVICE_INSTANCE 0
#define INVALID_CONN_ID 0xffff
#define HID_REPORT_ID_KEYBOARD 1
#define VENDOR_VALUE_MAX 192

static const uint8_t s_keyboard_report_map[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01,
    0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x03, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05,
    0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x03,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
    0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xc0,
};

static esp_hid_raw_report_map_t s_report_maps[] = {
    {.data = s_keyboard_report_map, .len = sizeof(s_keyboard_report_map)},
};

static esp_hid_device_config_t s_hid_config = {
    .vendor_id = 0x303a,
    .product_id = 0x4001,
    .version = 0x0100,
    .device_name = "Cardputer Bridge",
    .manufacturer_name = "Cardputer Bridge",
    .serial_number = "CB-ADV-0001",
    .report_maps = s_report_maps,
    .report_maps_len = 1,
};

// HID service 0x1812 encoded as a Bluetooth Base UUID. Bluedroid's legacy
// advertising API accepts service UUIDs only as 16-byte entries, even for a
// SIG-assigned 16-bit service.
static const uint8_t s_hid_service_uuid128[] = {
    0xfb, 0x34, 0x9b, 0x5f, 0x80, 0x00, 0x00, 0x80,
    0x00, 0x10, 0x00, 0x00, 0x12, 0x18, 0x00, 0x00,
};
_Static_assert(
    sizeof(s_hid_service_uuid128) % ESP_UUID_LEN_128 == 0,
    "Bluedroid advertising service UUIDs must use 128-bit entries"
);

// ESP-IDF stores 128-bit UUID bytes in reverse order from their canonical text.
// These values are fixed by Cardputer-Bridge-实现-Spec.md section 9.1.
// 15f98efe-c59c-46c4-be0f-29acfce5df6c
static const uint8_t s_vendor_service_uuid[16] = {
    0x6c, 0xdf, 0xe5, 0xfc, 0xac, 0x29, 0x0f, 0xbe,
    0xc4, 0x46, 0x9c, 0xc5, 0xfe, 0x8e, 0xf9, 0x15,
};
// f80db63e-1321-440f-b69a-984ed11206f8
static const uint8_t s_identity_uuid[16] = {
    0xf8, 0x06, 0x12, 0xd1, 0x4e, 0x98, 0x9a, 0xb6,
    0x0f, 0x44, 0x21, 0x13, 0x3e, 0xb6, 0x0d, 0xf8,
};
// 933966d7-0ad4-4412-aefe-ed53daae161f
static const uint8_t s_command_uuid[16] = {
    0x1f, 0x16, 0xae, 0xda, 0x53, 0xed, 0xfe, 0xae,
    0x12, 0x44, 0xd4, 0x0a, 0xd7, 0x66, 0x39, 0x93,
};
// ec577f1b-0005-4855-b939-66ea4b4427e4
static const uint8_t s_state_uuid[16] = {
    0xe4, 0x27, 0x44, 0x4b, 0xea, 0x66, 0x39, 0xb9,
    0x55, 0x48, 0x05, 0x00, 0x1b, 0x7f, 0x57, 0xec,
};
// 43554e05-3ed0-4c83-9463-7494bd9920ee
static const uint8_t s_heartbeat_uuid[16] = {
    0xee, 0x20, 0x99, 0xbd, 0x94, 0x74, 0x63, 0x94,
    0x83, 0x4c, 0xd0, 0x3e, 0x05, 0x4e, 0x55, 0x43,
};

static const uint16_t s_primary_service_uuid = ESP_GATT_UUID_PRI_SERVICE;
static const uint16_t s_characteristic_declaration_uuid = ESP_GATT_UUID_CHAR_DECLARE;
static const uint16_t s_cccd_uuid = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;
static const uint8_t s_identity_properties =
    ESP_GATT_CHAR_PROP_BIT_READ;
static const uint8_t s_command_properties =
    ESP_GATT_CHAR_PROP_BIT_WRITE;
static const uint8_t s_state_properties =
    ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_NOTIFY;
static const uint8_t s_heartbeat_properties =
    ESP_GATT_CHAR_PROP_BIT_WRITE | ESP_GATT_CHAR_PROP_BIT_WRITE_NR |
    ESP_GATT_CHAR_PROP_BIT_NOTIFY;
static uint8_t s_identity_value[VENDOR_VALUE_MAX] =
    "{\"v\":1,\"device\":\"Cardputer-ADV\",\"service\":\"CardputerBridge\"}";
static size_t s_identity_length =
    sizeof("{\"v\":1,\"device\":\"Cardputer-ADV\",\"service\":\"CardputerBridge\"}") - 1;
static uint8_t s_command_placeholder[1];
static uint8_t s_state_value[VENDOR_VALUE_MAX] = "{\"v\":1,\"mic_intent\":\"muted\"}";
static uint8_t s_cccd_value[2] = {0, 0};
static uint8_t s_heartbeat_placeholder[1];
static uint8_t s_heartbeat_cccd_value[2] = {0, 0};

enum {
    VENDOR_INDEX_SERVICE,
    VENDOR_INDEX_IDENTITY_DECLARATION,
    VENDOR_INDEX_IDENTITY_VALUE,
    VENDOR_INDEX_COMMAND_DECLARATION,
    VENDOR_INDEX_COMMAND_VALUE,
    VENDOR_INDEX_STATE_DECLARATION,
    VENDOR_INDEX_STATE_VALUE,
    VENDOR_INDEX_STATE_CCCD,
    VENDOR_INDEX_HEARTBEAT_DECLARATION,
    VENDOR_INDEX_HEARTBEAT_VALUE,
    VENDOR_INDEX_HEARTBEAT_CCCD,
    VENDOR_INDEX_COUNT,
};

static esp_gatts_attr_db_t s_vendor_database[VENDOR_INDEX_COUNT];
static uint16_t s_vendor_handles[VENDOR_INDEX_COUNT];
static esp_gatt_if_t s_vendor_interface = ESP_GATT_IF_NONE;
static uint16_t s_vendor_connection_id = INVALID_CONN_ID;
static bool s_state_subscribed;
static bool s_heartbeat_subscribed;

static esp_hidd_dev_t *s_hid_device;
static volatile bool s_hid_connected;
static volatile bool s_control_authenticated;
static volatile bool s_disconnect_event;
static volatile bool s_advertisement_configured;
static volatile bool s_hid_started;
static volatile bool s_service_change_sent_this_boot;

static ble_bridge_command_callback_t s_command_callback;
static void *s_command_context;
static ble_bridge_heartbeat_callback_t s_heartbeat_callback;
static void *s_heartbeat_context;

static volatile bool s_pairing_prompt_visible;
static volatile bool s_pairing_needs_confirmation;
static volatile uint32_t s_pairing_passkey;
static esp_bd_addr_t s_pairing_address;

static esp_ble_adv_params_t s_advertisement_parameters = {
    .adv_int_min = 0x20,
    .adv_int_max = 0x30,
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static esp_ble_adv_data_t s_advertisement_data = {
    .set_scan_rsp = false,
    .include_name = true,
    .include_txpower = false,
    // Omit the optional slave connection interval AD field so the complete
    // name, HID appearance and service UUID fit in the 31-byte legacy packet.
    .min_interval = 0,
    .max_interval = 0,
    .appearance = ESP_HID_APPEARANCE_KEYBOARD,
    .manufacturer_len = 0,
    .p_manufacturer_data = NULL,
    .service_data_len = 0,
    .p_service_data = NULL,
    .service_uuid_len = sizeof(s_hid_service_uuid128),
    .p_service_uuid = (uint8_t *)s_hid_service_uuid128,
    .flag = ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT,
};

static void start_advertising_if_ready(void) {
    if (s_advertisement_configured && s_hid_started && !s_hid_connected) {
        esp_err_t result = esp_ble_gap_start_advertising(&s_advertisement_parameters);
        if (result != ESP_OK && result != ESP_ERR_INVALID_STATE) {
            ESP_LOGE(TAG, "advertising start failed: %s", esp_err_to_name(result));
        }
    }
}

static void build_vendor_database(void) {
    memset(s_vendor_database, 0, sizeof(s_vendor_database));

    s_vendor_database[VENDOR_INDEX_SERVICE] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_16, (uint8_t *)&s_primary_service_uuid,
                     ESP_GATT_PERM_READ, sizeof(s_vendor_service_uuid),
                     sizeof(s_vendor_service_uuid), (uint8_t *)s_vendor_service_uuid},
    };
    s_vendor_database[VENDOR_INDEX_IDENTITY_DECLARATION] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_16, (uint8_t *)&s_characteristic_declaration_uuid,
                     ESP_GATT_PERM_READ, sizeof(s_identity_properties),
                     sizeof(s_identity_properties), (uint8_t *)&s_identity_properties},
    };
    s_vendor_database[VENDOR_INDEX_IDENTITY_VALUE] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_128, (uint8_t *)s_identity_uuid,
                     ESP_GATT_PERM_READ_ENC_MITM, sizeof(s_identity_value),
                     s_identity_length, s_identity_value},
    };
    s_vendor_database[VENDOR_INDEX_COMMAND_DECLARATION] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_16, (uint8_t *)&s_characteristic_declaration_uuid,
                     ESP_GATT_PERM_READ, sizeof(s_command_properties),
                     sizeof(s_command_properties), (uint8_t *)&s_command_properties},
    };
    s_vendor_database[VENDOR_INDEX_COMMAND_VALUE] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_RSP_BY_APP},
        .att_desc = {ESP_UUID_LEN_128, (uint8_t *)s_command_uuid,
                     ESP_GATT_PERM_WRITE_ENC_MITM, VENDOR_VALUE_MAX,
                     sizeof(s_command_placeholder), s_command_placeholder},
    };
    s_vendor_database[VENDOR_INDEX_STATE_DECLARATION] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_16, (uint8_t *)&s_characteristic_declaration_uuid,
                     ESP_GATT_PERM_READ, sizeof(s_state_properties),
                     sizeof(s_state_properties), (uint8_t *)&s_state_properties},
    };
    s_vendor_database[VENDOR_INDEX_STATE_VALUE] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_128, (uint8_t *)s_state_uuid,
                     ESP_GATT_PERM_READ_ENC_MITM, sizeof(s_state_value),
                     strlen((const char *)s_state_value), s_state_value},
    };
    s_vendor_database[VENDOR_INDEX_STATE_CCCD] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_16, (uint8_t *)&s_cccd_uuid,
                     ESP_GATT_PERM_READ_ENC_MITM | ESP_GATT_PERM_WRITE_ENC_MITM,
                     sizeof(s_cccd_value), sizeof(s_cccd_value), s_cccd_value},
    };
    s_vendor_database[VENDOR_INDEX_HEARTBEAT_DECLARATION] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_16, (uint8_t *)&s_characteristic_declaration_uuid,
                     ESP_GATT_PERM_READ, sizeof(s_heartbeat_properties),
                     sizeof(s_heartbeat_properties), (uint8_t *)&s_heartbeat_properties},
    };
    s_vendor_database[VENDOR_INDEX_HEARTBEAT_VALUE] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_RSP_BY_APP},
        .att_desc = {ESP_UUID_LEN_128, (uint8_t *)s_heartbeat_uuid,
                     ESP_GATT_PERM_WRITE_ENC_MITM, VENDOR_VALUE_MAX,
                     sizeof(s_heartbeat_placeholder), s_heartbeat_placeholder},
    };
    s_vendor_database[VENDOR_INDEX_HEARTBEAT_CCCD] = (esp_gatts_attr_db_t){
        .attr_control = {ESP_GATT_AUTO_RSP},
        .att_desc = {ESP_UUID_LEN_16, (uint8_t *)&s_cccd_uuid,
                     ESP_GATT_PERM_READ_ENC_MITM | ESP_GATT_PERM_WRITE_ENC_MITM,
                     sizeof(s_heartbeat_cccd_value), sizeof(s_heartbeat_cccd_value),
                     s_heartbeat_cccd_value},
    };
}

static void vendor_gatts_event_handler(
    esp_gatts_cb_event_t event,
    esp_gatt_if_t gatts_if,
    esp_ble_gatts_cb_param_t *param
) {
    switch (event) {
        case ESP_GATTS_REG_EVT:
            if (param->reg.status != ESP_GATT_OK || param->reg.app_id != VENDOR_APP_ID) {
                return;
            }
            s_vendor_interface = gatts_if;
            esp_ble_gatts_create_attr_tab(
                s_vendor_database,
                gatts_if,
                VENDOR_INDEX_COUNT,
                VENDOR_SERVICE_INSTANCE
            );
            break;
        case ESP_GATTS_CREAT_ATTR_TAB_EVT:
            if (param->add_attr_tab.status != ESP_GATT_OK ||
                param->add_attr_tab.num_handle != VENDOR_INDEX_COUNT) {
                ESP_LOGE(TAG, "vendor attribute table failed: status=%d handles=%u",
                         param->add_attr_tab.status, param->add_attr_tab.num_handle);
                return;
            }
            memcpy(s_vendor_handles, param->add_attr_tab.handles, sizeof(s_vendor_handles));
            esp_ble_gatts_start_service(s_vendor_handles[VENDOR_INDEX_SERVICE]);
            ESP_LOGI(TAG, "vendor GATT service ready");
            break;
        case ESP_GATTS_CONNECT_EVT:
            s_vendor_connection_id = param->connect.conn_id;
            {
                const esp_err_t security_result = esp_ble_set_encryption(
                    param->connect.remote_bda,
                    ESP_BLE_SEC_ENCRYPT_MITM
                );
                if (security_result != ESP_OK) {
                    ESP_LOGE(TAG, "MITM encryption request failed: %s",
                             esp_err_to_name(security_result));
                } else {
                    ESP_LOGI(TAG, "MITM encryption requested");
                }
            }
            break;
        case ESP_GATTS_DISCONNECT_EVT:
            s_vendor_connection_id = INVALID_CONN_ID;
            s_state_subscribed = false;
            s_heartbeat_subscribed = false;
            break;
        case ESP_GATTS_WRITE_EVT: {
            esp_gatt_status_t status = ESP_GATT_OK;
            if (param->write.handle == s_vendor_handles[VENDOR_INDEX_COMMAND_VALUE]) {
                if (param->write.is_prep || param->write.len > VENDOR_VALUE_MAX) {
                    status = ESP_GATT_INVALID_ATTR_LEN;
                } else if (s_command_callback != NULL) {
                    s_command_callback(param->write.value, param->write.len, s_command_context);
                }
            } else if (param->write.handle ==
                       s_vendor_handles[VENDOR_INDEX_HEARTBEAT_VALUE]) {
                if (param->write.is_prep || param->write.len > VENDOR_VALUE_MAX) {
                    status = ESP_GATT_INVALID_ATTR_LEN;
                } else if (s_heartbeat_callback != NULL) {
                    s_heartbeat_callback(
                        param->write.value,
                        param->write.len,
                        s_heartbeat_context
                    );
                }
            } else if (param->write.handle == s_vendor_handles[VENDOR_INDEX_STATE_CCCD] &&
                       param->write.len == 2) {
                const uint16_t value = (uint16_t)param->write.value[0] |
                    ((uint16_t)param->write.value[1] << 8);
                s_state_subscribed = value == 0x0001;
            } else if (param->write.handle ==
                           s_vendor_handles[VENDOR_INDEX_HEARTBEAT_CCCD] &&
                       param->write.len == 2) {
                const uint16_t value = (uint16_t)param->write.value[0] |
                    ((uint16_t)param->write.value[1] << 8);
                s_heartbeat_subscribed = value == 0x0001;
            }
            if (param->write.need_rsp) {
                esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                            param->write.trans_id, status, NULL);
            }
            break;
        }
        default:
            break;
    }
}

static void gatts_router(
    esp_gatts_cb_event_t event,
    esp_gatt_if_t gatts_if,
    esp_ble_gatts_cb_param_t *param
) {
    const bool vendor_registration = event == ESP_GATTS_REG_EVT &&
        param->reg.app_id == VENDOR_APP_ID;
    const bool vendor_interface_event = s_vendor_interface != ESP_GATT_IF_NONE &&
        gatts_if == s_vendor_interface;
    if (vendor_registration || vendor_interface_event) {
        vendor_gatts_event_handler(event, gatts_if, param);
        return;
    }
    esp_hidd_gatts_event_handler(event, gatts_if, param);
}

static void gap_event_handler(
    esp_gap_ble_cb_event_t event,
    esp_ble_gap_cb_param_t *param
) {
    switch (event) {
        case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
            s_advertisement_configured = param->adv_data_cmpl.status == ESP_BT_STATUS_SUCCESS;
            start_advertising_if_ready();
            break;
        case ESP_GAP_BLE_SEC_REQ_EVT:
            esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, true);
            break;
        case ESP_GAP_BLE_NC_REQ_EVT:
            memcpy(s_pairing_address, param->ble_security.key_notif.bd_addr,
                   sizeof(s_pairing_address));
            s_pairing_passkey = param->ble_security.key_notif.passkey;
            s_pairing_needs_confirmation = true;
            s_pairing_prompt_visible = true;
            ESP_LOGI(TAG, "numeric comparison pending: %06" PRIu32,
                     s_pairing_passkey);
            break;
        case ESP_GAP_BLE_PASSKEY_NOTIF_EVT:
            memcpy(s_pairing_address, param->ble_security.key_notif.bd_addr,
                   sizeof(s_pairing_address));
            s_pairing_passkey = param->ble_security.key_notif.passkey;
            s_pairing_needs_confirmation = false;
            s_pairing_prompt_visible = true;
            ESP_LOGI(TAG, "pairing passkey: %06" PRIu32, s_pairing_passkey);
            break;
        case ESP_GAP_BLE_AUTH_CMPL_EVT:
            s_control_authenticated = param->ble_security.auth_cmpl.success;
            s_pairing_prompt_visible = false;
            s_pairing_needs_confirmation = false;
            if (!s_control_authenticated) {
                ESP_LOGE(TAG, "BLE authentication failed: 0x%x",
                         param->ble_security.auth_cmpl.fail_reason);
            } else if (!s_service_change_sent_this_boot &&
                       s_vendor_interface != ESP_GATT_IF_NONE) {
                const esp_err_t service_change_result =
                    esp_ble_gatts_send_service_change_indication(
                        s_vendor_interface,
                        param->ble_security.auth_cmpl.bd_addr
                    );
                if (service_change_result == ESP_OK) {
                    s_service_change_sent_this_boot = true;
                    ESP_LOGI(TAG, "GATT service change indication queued");
                } else {
                    ESP_LOGW(TAG, "GATT service change indication failed: %s",
                             esp_err_to_name(service_change_result));
                }
            }
            break;
        default:
            break;
    }
}

static void hid_event_handler(
    void *handler_args,
    esp_event_base_t base,
    int32_t id,
    void *event_data
) {
    (void)handler_args;
    (void)base;
    (void)event_data;
    switch ((esp_hidd_event_t)id) {
        case ESP_HIDD_START_EVENT:
            s_hid_started = true;
            start_advertising_if_ready();
            break;
        case ESP_HIDD_CONNECT_EVENT:
            s_hid_connected = true;
            ESP_LOGI(TAG, "BLE HID connected");
            break;
        case ESP_HIDD_DISCONNECT_EVENT:
            s_hid_connected = false;
            s_control_authenticated = false;
            s_disconnect_event = true;
            ESP_LOGI(TAG, "BLE HID disconnected");
            start_advertising_if_ready();
            break;
        default:
            break;
    }
}

static esp_err_t trace_start_result(const char *stage, esp_err_t result) {
    if (result != ESP_OK) {
        ESP_LOGE(TAG, "BLE startup stage %s failed: %s",
                 stage, esp_err_to_name(result));
    }
    return result;
}

static esp_err_t initialize_bluetooth_stack(void) {
    esp_err_t result = esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
    if (result != ESP_OK && result != ESP_ERR_INVALID_STATE) {
        return trace_start_result("controller_mem_release", result);
    }

    esp_bt_controller_config_t controller_config = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    result = esp_bt_controller_init(&controller_config);
    if (result != ESP_OK) {
        return trace_start_result("controller_init", result);
    }
    result = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (result != ESP_OK) {
        return trace_start_result("controller_enable", result);
    }
    esp_bluedroid_config_t bluedroid_config = BT_BLUEDROID_INIT_CONFIG_DEFAULT();
    result = esp_bluedroid_init_with_cfg(&bluedroid_config);
    if (result != ESP_OK) {
        return trace_start_result("bluedroid_init", result);
    }
    return trace_start_result("bluedroid_enable", esp_bluedroid_enable());
}

static esp_err_t configure_gap(void) {
    esp_err_t result = esp_ble_gap_register_callback(gap_event_handler);
    if (result != ESP_OK) {
        return trace_start_result("gap_register_callback", result);
    }

    esp_ble_auth_req_t authentication = ESP_LE_AUTH_REQ_SC_MITM_BOND;
    esp_ble_io_cap_t io_capability = ESP_IO_CAP_IO;
    uint8_t initial_keys = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t response_keys = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t key_size = 16;
    result = esp_ble_gap_set_security_param(
        ESP_BLE_SM_AUTHEN_REQ_MODE, &authentication, sizeof(authentication));
    trace_start_result("gap_security_auth", result);
    if (result == ESP_OK) {
        result = esp_ble_gap_set_security_param(
            ESP_BLE_SM_IOCAP_MODE, &io_capability, sizeof(io_capability));
        trace_start_result("gap_security_iocap", result);
    }
    if (result == ESP_OK) {
        result = esp_ble_gap_set_security_param(
            ESP_BLE_SM_SET_INIT_KEY, &initial_keys, sizeof(initial_keys));
        trace_start_result("gap_security_init_key", result);
    }
    if (result == ESP_OK) {
        result = esp_ble_gap_set_security_param(
            ESP_BLE_SM_SET_RSP_KEY, &response_keys, sizeof(response_keys));
        trace_start_result("gap_security_rsp_key", result);
    }
    if (result == ESP_OK) {
        result = esp_ble_gap_set_security_param(
            ESP_BLE_SM_MAX_KEY_SIZE, &key_size, sizeof(key_size));
        trace_start_result("gap_security_key_size", result);
    }
    if (result == ESP_OK) {
        result = esp_ble_gap_set_device_name(s_hid_config.device_name);
        trace_start_result("gap_device_name", result);
    }
    if (result == ESP_OK) {
        result = esp_ble_gap_config_adv_data(&s_advertisement_data);
        trace_start_result("gap_adv_data", result);
    }
    return result;
}

esp_err_t ble_bridge_start(
    ble_bridge_command_callback_t command_callback,
    void *command_context,
    ble_bridge_heartbeat_callback_t heartbeat_callback,
    void *heartbeat_context
) {
    s_command_callback = command_callback;
    s_command_context = command_context;
    s_heartbeat_callback = heartbeat_callback;
    s_heartbeat_context = heartbeat_context;
    build_vendor_database();

    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES || result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        result = nvs_flash_init();
    }
    if (result != ESP_OK) {
        return trace_start_result("nvs_init", result);
    }
    result = initialize_bluetooth_stack();
    if (result != ESP_OK) {
        return result;
    }
    result = configure_gap();
    if (result != ESP_OK) {
        return result;
    }
    result = esp_ble_gatts_register_callback(gatts_router);
    if (result != ESP_OK) {
        return trace_start_result("gatts_register_callback", result);
    }
    result = esp_hidd_dev_init(
        &s_hid_config,
        ESP_HID_TRANSPORT_BLE,
        hid_event_handler,
        &s_hid_device
    );
    if (result != ESP_OK) {
        return trace_start_result("hid_device_init", result);
    }
    return trace_start_result(
        "vendor_app_register",
        esp_ble_gatts_app_register(VENDOR_APP_ID)
    );
}

bool ble_bridge_hid_connected(void) {
    return s_hid_connected;
}

esp_err_t ble_bridge_set_identity(const char *identity_json) {
    if (identity_json == NULL) return ESP_ERR_INVALID_ARG;
    const size_t length = strnlen(identity_json, sizeof(s_identity_value));
    if (length == sizeof(s_identity_value)) return ESP_ERR_INVALID_SIZE;
    memcpy(s_identity_value, identity_json, length);
    s_identity_value[length] = '\0';
    s_identity_length = length;
    return ESP_OK;
}

bool ble_bridge_control_authenticated(void) {
    return s_control_authenticated;
}

bool ble_bridge_take_disconnect_event(void) {
    const bool result = s_disconnect_event;
    s_disconnect_event = false;
    return result;
}

ble_bridge_pairing_prompt_t ble_bridge_pairing_prompt(void) {
    return (ble_bridge_pairing_prompt_t){
        .visible = s_pairing_prompt_visible,
        .needs_confirmation = s_pairing_needs_confirmation,
        .passkey = s_pairing_passkey,
    };
}

esp_err_t ble_bridge_confirm_pairing(bool accept) {
    if (!s_pairing_prompt_visible || !s_pairing_needs_confirmation) {
        return ESP_ERR_INVALID_STATE;
    }
    s_pairing_prompt_visible = false;
    s_pairing_needs_confirmation = false;
    return esp_ble_confirm_reply(s_pairing_address, accept);
}

esp_err_t ble_bridge_send_hid(uint8_t modifiers, uint8_t usage) {
    if (!s_hid_connected || s_hid_device == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    uint8_t report[8] = {0};
    report[0] = modifiers;
    report[2] = usage;
    return esp_hidd_dev_input_set(
        s_hid_device,
        0,
        HID_REPORT_ID_KEYBOARD,
        report,
        sizeof(report)
    );
}

esp_err_t ble_bridge_notify_state(const char *state_json) {
    if (state_json == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    const size_t length = strnlen(state_json, sizeof(s_state_value));
    if (length == sizeof(s_state_value)) {
        return ESP_ERR_INVALID_SIZE;
    }
    memcpy(s_state_value, state_json, length);
    s_state_value[length] = '\0';
    if (s_vendor_handles[VENDOR_INDEX_STATE_VALUE] != 0) {
        esp_ble_gatts_set_attr_value(
            s_vendor_handles[VENDOR_INDEX_STATE_VALUE],
            length,
            s_state_value
        );
    }
    if (!s_state_subscribed || !s_control_authenticated ||
        s_vendor_connection_id == INVALID_CONN_ID) {
        return ESP_OK;
    }
    return esp_ble_gatts_send_indicate(
        s_vendor_interface,
        s_vendor_connection_id,
        s_vendor_handles[VENDOR_INDEX_STATE_VALUE],
        length,
        s_state_value,
        false
    );
}
