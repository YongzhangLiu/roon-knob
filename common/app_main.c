#include "app.h"

#include "platform/platform_log.h"
#include "platform/platform_mdns.h"
#include "platform/platform_storage.h"
#include "rk_cfg.h"
#include "bridge_client.h"
#include "controller_legacy_binding.h"

#include <stdbool.h>

void app_entry(void) {
    rk_cfg_t cfg = {0};
    bool valid = platform_storage_load(&cfg) && rk_cfg_is_valid(&cfg);
    if (!valid) {
        LOGI("config missing - applying defaults");
        platform_storage_defaults(&cfg);
        platform_storage_save(&cfg);
    }

    // Note: mDNS init moved to after WiFi connects (in main_idf.c)
    controller_input_set_action_handler(controller_legacy_binding_handle_action);
    controller_input_set_rotation_handler(
        controller_legacy_binding_handle_rotation);
    bridge_client_start(&cfg);
}
