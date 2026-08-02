#pragma once

#include <stdint.h>

#ifdef ESP_PLATFORM
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

static inline void os_sleep_ms(uint32_t ms) {
    vTaskDelay(pdMS_TO_TICKS(ms));
}

static inline void os_sleep_us(uint32_t us) {
    if (us < 1000) {
        uint32_t start = esp_timer_get_time();
        while ((esp_timer_get_time() - start) < us) {
            // busy wait for short delays
        }
    } else {
        vTaskDelay(pdMS_TO_TICKS(us / 1000));
    }
}

static inline void os_sleep_sec(uint32_t sec) {
    vTaskDelay(pdMS_TO_TICKS(sec * 1000));
}

#else
#include <unistd.h>

static inline void os_sleep_ms(uint32_t ms) {
    usleep(ms * 1000);
}

static inline void os_sleep_us(uint32_t us) {
    usleep(us);
}

static inline void os_sleep_sec(uint32_t sec) {
    sleep(sec);
}

#endif
