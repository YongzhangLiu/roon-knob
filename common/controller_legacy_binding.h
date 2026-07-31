#pragma once

#include "controller_input.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Transitional mapping from the command-bound input API and renderer-owned
 * picker state to typed controller commands. Issue #194 owns its retirement.
 */
void controller_legacy_binding_handle_action(controller_input_action_t action);
void controller_legacy_binding_handle_rotation(int ticks);

#ifdef __cplusplus
}
#endif
