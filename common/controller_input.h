#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Normalized controller input: touch UI, encoders, physical buttons,
// joysticks, and BLE all emit through this dispatcher without knowing about
// the bridge client. The bridge registers its handlers once at startup.

typedef enum {
    CONTROLLER_INPUT_VOL_DOWN = -1,
    CONTROLLER_INPUT_NONE = 0,
    CONTROLLER_INPUT_VOL_UP = 1,
    CONTROLLER_INPUT_PLAY_PAUSE = 2,
    CONTROLLER_INPUT_MENU = 3,
    CONTROLLER_INPUT_NEXT_TRACK = 4,
    CONTROLLER_INPUT_PREV_TRACK = 5,
} controller_input_action_t;

typedef void (*controller_input_action_handler_t)(controller_input_action_t action);
typedef void (*controller_input_rotation_handler_t)(int ticks);  // Velocity-aware: accumulated ticks per sample window

void controller_input_set_action_handler(controller_input_action_handler_t handler);
void controller_input_set_rotation_handler(controller_input_rotation_handler_t handler);

void controller_input_dispatch_action(controller_input_action_t action);
void controller_input_dispatch_rotation(int ticks);

// Queue an action for dispatch on the target's UI/event loop. Input callbacks
// from BLE, timers, and other subsystem tasks must use this form when handling
// the action can perform network I/O or mutate presentation state.
bool controller_input_post_action(controller_input_action_t action);

#ifdef __cplusplus
}
#endif
