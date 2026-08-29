#include <M5Unified.h>

#include <cstdint>
#include <cstdio>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"

namespace {

constexpr std::uint32_t kRedHoldMs = 20'000;
constexpr std::uint32_t kOffHoldMs = 5'000;

void set_led(bool red) {
    M5.Led.setBrightness(255);
    M5.Led.setAllColor(
        static_cast<std::uint8_t>(red ? 255 : 0),
        static_cast<std::uint8_t>(0),
        static_cast<std::uint8_t>(0)
    );
    std::printf(
        "{\"v\":1,\"event\":\"led_diagnostic_transition\","
        "\"target\":\"%s\",\"driver_enabled\":%s,\"led_count\":%u}\n",
        red ? "red" : "off",
        M5.Led.isEnabled() ? "true" : "false",
        static_cast<unsigned>(M5.Led.getCount())
    );
}

}  // namespace

extern "C" void app_main(void) {
    const auto config = M5.config();
    M5.begin(config);

    // Cardputer ADV's Stamp-S3A gates the WS2812 supply independently.
    // GPIO21 carries data, while GPIO38 must stay high for the LED to retain
    // the transmitted color. Reset the pad first to detach display PWM.
    gpio_reset_pin(GPIO_NUM_38);
    gpio_set_direction(GPIO_NUM_38, GPIO_MODE_OUTPUT);
    gpio_set_level(GPIO_NUM_38, 1);

    set_led(false);
    std::printf(
        "{\"v\":1,\"event\":\"led_diagnostic_ready\","
        "\"board\":%u,\"led_power_gpio\":38,"
        "\"led_power_enabled\":true,"
        "\"pattern\":\"red_20s_off_5s\"}\n",
        static_cast<unsigned>(M5.getBoard())
    );
    vTaskDelay(pdMS_TO_TICKS(1000));

    while (true) {
        set_led(true);
        vTaskDelay(pdMS_TO_TICKS(kRedHoldMs));
        set_led(false);
        vTaskDelay(pdMS_TO_TICKS(kOffHoldMs));
    }
}
