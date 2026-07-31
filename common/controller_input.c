#include "controller_input.h"
#include "platform/platform_task.h"

#include <stdint.h>
#include <stddef.h>

static controller_input_action_handler_t s_action_handler;
static controller_input_rotation_handler_t s_rotation_handler;

void controller_input_set_action_handler(controller_input_action_handler_t handler) {
    s_action_handler = handler;
}

void controller_input_set_rotation_handler(controller_input_rotation_handler_t handler) {
    s_rotation_handler = handler;
}

void controller_input_dispatch_action(controller_input_action_t action) {
    if (s_action_handler) {
        s_action_handler(action);
    }
}

void controller_input_dispatch_rotation(int ticks) {
    if (s_rotation_handler) {
        s_rotation_handler(ticks);
    }
}

static void dispatch_posted_action(void *arg) {
    controller_input_action_t action =
        (controller_input_action_t)(intptr_t)arg;
    controller_input_dispatch_action(action);
}

bool controller_input_post_action(controller_input_action_t action) {
    if (action == CONTROLLER_INPUT_NONE) {
        return false;
    }
    return platform_task_post_to_ui(dispatch_posted_action,
                                    (void *)(intptr_t)action);
}
