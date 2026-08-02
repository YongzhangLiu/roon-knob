#pragma once

#include "rk_cfg.h"

#include <stdbool.h>

bool platform_storage_load(rk_cfg_t *out);
bool platform_storage_save(const rk_cfg_t *in);
void platform_storage_defaults(rk_cfg_t *out);
void platform_storage_reset_wifi_only(rk_cfg_t *cfg);
