#include "controller_input.h"
#include "platform/platform_task.h"

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#define EXPECTED_QUEUE_CAPACITY 63

static controller_input_action_t s_actions[EXPECTED_QUEUE_CAPACITY + 2];
static size_t s_action_count;
static int s_rotation_ticks;
static int s_reentrant_trace[2];
static size_t s_reentrant_count;

static void record_action(controller_input_action_t action) {
    assert(s_action_count < (sizeof(s_actions) / sizeof(s_actions[0])));
    s_actions[s_action_count++] = action;
}
static void record_rotation(int ticks) {
    s_rotation_ticks = ticks;
}

static void reentrant_second(void *arg) {
    (void)arg;
    assert(s_reentrant_count < 2);
    s_reentrant_trace[s_reentrant_count++] = 2;
}

static void reentrant_first(void *arg) {
    (void)arg;
    assert(s_reentrant_count < 2);
    s_reentrant_trace[s_reentrant_count++] = 1;
    assert(platform_task_post_to_ui(reentrant_second, NULL));
}

static void test_direct_dispatch_and_unset_handlers(void) {
    controller_input_set_action_handler(NULL);
    controller_input_set_rotation_handler(NULL);
    controller_input_dispatch_action(CONTROLLER_INPUT_PLAY_PAUSE);
    controller_input_dispatch_rotation(7);

    controller_input_set_action_handler(record_action);
    controller_input_set_rotation_handler(record_rotation);
    controller_input_dispatch_action(CONTROLLER_INPUT_NEXT_TRACK);
    controller_input_dispatch_rotation(-4);

    assert(s_action_count == 1);
    assert(s_actions[0] == CONTROLLER_INPUT_NEXT_TRACK);
    assert(s_rotation_ticks == -4);
}

static void test_none_is_not_queued(void) {
    assert(!controller_input_post_action(CONTROLLER_INPUT_NONE));
}

static void test_queue_fifo_capacity_and_full_failure(void) {
    s_action_count = 0;
    for (size_t i = 0; i < EXPECTED_QUEUE_CAPACITY; ++i) {
        controller_input_action_t action =
            (i % 2 == 0) ? CONTROLLER_INPUT_VOL_DOWN
                         : CONTROLLER_INPUT_VOL_UP;
        assert(controller_input_post_action(action));
    }

    assert(!controller_input_post_action(CONTROLLER_INPUT_PLAY_PAUSE));
    platform_task_run_pending();

    assert(s_action_count == EXPECTED_QUEUE_CAPACITY);
    for (size_t i = 0; i < EXPECTED_QUEUE_CAPACITY; ++i) {
        controller_input_action_t expected =
            (i % 2 == 0) ? CONTROLLER_INPUT_VOL_DOWN
                         : CONTROLLER_INPUT_VOL_UP;
        assert(s_actions[i] == expected);
    }
}

static void test_reentrant_post_runs_in_same_drain(void) {
    s_reentrant_count = 0;
    assert(platform_task_post_to_ui(reentrant_first, NULL));
    platform_task_run_pending();

    assert(s_reentrant_count == 2);
    assert(s_reentrant_trace[0] == 1);
    assert(s_reentrant_trace[1] == 2);
}

int main(void) {
    test_direct_dispatch_and_unset_handlers();
    test_none_is_not_queued();
    test_queue_fifo_capacity_and_full_failure();
    test_reentrant_post_runs_in_same_drain();
    puts("controller input/task contracts passed");
    return 0;
}
