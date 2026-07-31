#include "controller_ble_input.h"

#include "controller_input.h"

#include <esp_log.h>

static const char *TAG = "controller_ble";

void controller_ble_input_on_media_key(rk_ble_media_key_t key, void *context) {
    (void)context;

    controller_input_action_t action = CONTROLLER_INPUT_NONE;
    switch (key) {
    case RK_BLE_MEDIA_KEY_PLAY_PAUSE:
        action = CONTROLLER_INPUT_PLAY_PAUSE;
        break;
    case RK_BLE_MEDIA_KEY_NEXT_TRACK:
        action = CONTROLLER_INPUT_NEXT_TRACK;
        break;
    case RK_BLE_MEDIA_KEY_PREVIOUS_TRACK:
        action = CONTROLLER_INPUT_PREV_TRACK;
        break;
    case RK_BLE_MEDIA_KEY_VOLUME_UP:
        action = CONTROLLER_INPUT_VOL_UP;
        break;
    case RK_BLE_MEDIA_KEY_VOLUME_DOWN:
        action = CONTROLLER_INPUT_VOL_DOWN;
        break;
    case RK_BLE_MEDIA_KEY_NONE:
    default:
        return;
    }

    if (!controller_input_post_action(action)) {
        ESP_LOGW(TAG, "Controller input queue full; BLE media key %d dropped",
                 key);
    }
}
