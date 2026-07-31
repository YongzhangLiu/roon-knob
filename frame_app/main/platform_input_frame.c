// platform_input.h implementation for PhotoPainter buttons
// BOOT (GPIO0): long press=WiFi setup AP mode (only action)
// GP4  (GPIO4): long press=restart
// PWR  (GPIO5): unused

#include "platform/platform_input.h"
#include "wifi_manager.h"

#include <driver/gpio.h>
#include <esp_log.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

static const char *TAG = "input";

#define BOOT_PIN  0
#define GP4_PIN   4
#define PWR_PIN   5

#define LONG_PRESS_MS 1000
#define DEBOUNCE_MS   50

static QueueHandle_t s_event_queue = NULL;
static esp_timer_handle_t s_btn_poll_timer = NULL;

typedef enum {
    FRAME_INPUT_NONE = 0,
    FRAME_INPUT_START_PROVISIONING,
    FRAME_INPUT_RESTART,
} frame_input_event_t;

// Button state tracking
typedef struct {
    gpio_num_t pin;
    uint8_t active_low;  // 1 = active low (pressed = 0), 0 = active high
    uint64_t press_time;
    bool pressed;
} button_state_t;

static button_state_t s_boot = {BOOT_PIN, 1, 0, false};
static button_state_t s_gp4  = {GP4_PIN,  1, 0, false};
static button_state_t s_pwr  = {PWR_PIN,  0, 0, false};  // PWR is active high

static bool is_pressed(button_state_t *btn) {
    int level = gpio_get_level(btn->pin);
    return btn->active_low ? (level == 0) : (level == 1);
}

static void poll_button(button_state_t *btn,
                        frame_input_event_t short_evt,
                        frame_input_event_t long_evt) {
    bool now_pressed = is_pressed(btn);
    uint64_t now = esp_timer_get_time() / 1000;  // ms

    if (now_pressed && !btn->pressed) {
        // Button just pressed
        btn->pressed = true;
        btn->press_time = now;
    } else if (!now_pressed && btn->pressed) {
        // Button released
        btn->pressed = false;
        uint64_t held = now - btn->press_time;
        if (held >= LONG_PRESS_MS && long_evt != FRAME_INPUT_NONE) {
            if (s_event_queue) xQueueSend(s_event_queue, &long_evt, 0);
        } else if (held >= DEBOUNCE_MS && short_evt != FRAME_INPUT_NONE) {
            if (s_event_queue) xQueueSend(s_event_queue, &short_evt, 0);
        }
    }
}

// Track GP4 long-press for restart (handled outside the event queue)
static volatile bool s_restart_pending = false;

static void button_poll_cb(void *arg) {
    (void)arg;
    // BOOT: long press only = WiFi AP setup
    poll_button(&s_boot, FRAME_INPUT_NONE, FRAME_INPUT_START_PROVISIONING);
    // GP4/PWR: poll_button updates internal press state (press_time, pressed)
    // needed by the long-press restart check below, even though no events are enqueued
    poll_button(&s_gp4, FRAME_INPUT_NONE, FRAME_INPUT_NONE);
    poll_button(&s_pwr, FRAME_INPUT_NONE, FRAME_INPUT_NONE);

    // Check GP4 for restart (long press detection directly)
    bool gp4_pressed = is_pressed(&s_gp4);
    if (gp4_pressed && s_gp4.pressed) {
        uint64_t held = (esp_timer_get_time() / 1000) - s_gp4.press_time;
        if (held >= LONG_PRESS_MS && !s_restart_pending) {
            s_restart_pending = true;
            frame_input_event_t evt = FRAME_INPUT_RESTART;
            if (s_event_queue) xQueueSend(s_event_queue, &evt, 0);
        }
    }
}

void platform_input_init(void) {
    s_event_queue = xQueueCreate(8, sizeof(frame_input_event_t));

    // Active-low buttons (BOOT, GP4): pull-up, read 0 when pressed
    gpio_config_t io_conf = {
        .intr_type = GPIO_INTR_DISABLE,
        .mode = GPIO_MODE_INPUT,
        .pin_bit_mask = (1ULL << BOOT_PIN) | (1ULL << GP4_PIN),
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    gpio_config(&io_conf);

    // Active-high button (PWR): pull-down, read 1 when pressed
    gpio_config_t pwr_conf = {
        .intr_type = GPIO_INTR_DISABLE,
        .mode = GPIO_MODE_INPUT,
        .pin_bit_mask = (1ULL << PWR_PIN),
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .pull_up_en = GPIO_PULLUP_DISABLE,
    };
    gpio_config(&pwr_conf);

    // Timer to poll buttons every 10ms
    esp_timer_create_args_t timer_args = {
        .callback = button_poll_cb,
        .name = "btn_poll",
    };
    if (esp_timer_create(&timer_args, &s_btn_poll_timer) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create button poll timer");
        return;
    }
    if (esp_timer_start_periodic(s_btn_poll_timer, 10 * 1000) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start button poll timer");
        esp_timer_delete(s_btn_poll_timer);
        s_btn_poll_timer = NULL;
        return;
    }

    ESP_LOGI(TAG, "Button input initialized (BOOT=%d, GP4=%d, PWR=%d)",
             BOOT_PIN, GP4_PIN, PWR_PIN);
}

void platform_input_process_events(void) {
    frame_input_event_t evt;
    while (s_event_queue && xQueueReceive(s_event_queue, &evt, 0) == pdTRUE) {
        ESP_LOGI(TAG, "Input event: %d", evt);
        switch (evt) {
        case FRAME_INPUT_START_PROVISIONING:
            ESP_LOGW(TAG, "BOOT long press — starting WiFi provisioning");
            wifi_mgr_start_provisioning();
            break;
        case FRAME_INPUT_RESTART:
            ESP_LOGW(TAG, "GP4 long press — restarting");
            esp_restart();
            break;
        default:
            break;
        }
    }
}

void platform_input_shutdown(void) {
    if (s_btn_poll_timer) {
        esp_timer_stop(s_btn_poll_timer);
        esp_timer_delete(s_btn_poll_timer);
        s_btn_poll_timer = NULL;
    }
    if (s_event_queue) {
        vQueueDelete(s_event_queue);
        s_event_queue = NULL;
    }
}
