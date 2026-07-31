#include "app.h"

#include "platform/platform_log.h"
#include "platform/platform_mdns.h"
#include "platform/platform_storage.h"
#include "rk_cfg.h"
#include "bridge_client.h"
#include "controller_action_router.h"
#include "controller_input.h"

#include <stdbool.h>

static bool s_controller_initialized;

void app_controller_init(void) {
    if (s_controller_initialized) {
        return;
    }
    controller_action_router_init();
    controller_input_reset_control_mailbox_stats();
    controller_input_set_action_handler(controller_action_router_handle);
    s_controller_initialized = true;
}

void app_entry(void) {
    rk_cfg_t cfg = {0};
    bool valid = platform_storage_load(&cfg) && rk_cfg_is_valid(&cfg);
    if (!valid) {
        LOGI("config missing - applying defaults");
        platform_storage_defaults(&cfg);
        platform_storage_save(&cfg);
    }

    // Note: mDNS init moved to after WiFi connects (in main_idf.c)
    app_controller_init();
    bridge_client_start(&cfg);
}
