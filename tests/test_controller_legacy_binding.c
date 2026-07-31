#include "bridge_client.h"
#include "controller_legacy_binding.h"
#include "controller_presentation.h"
#include "platform/platform_task.h"

#include <assert.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define TEST_CAPACITY 32

typedef enum {
    TRACE_SHOW_PICKER = 1,
    TRACE_HIDE_PICKER,
    TRACE_SHOW_SETTINGS,
    TRACE_SCROLL,
    TRACE_NETWORK_STATUS,
    TRACE_ZONE_NAME,
    TRACE_MESSAGE,
} trace_event_t;

typedef struct {
    platform_task_fn_t fn;
    void *arg;
} queued_task_t;

static trace_event_t s_trace[TEST_CAPACITY];
static int s_trace_count;
static int s_scroll_values[TEST_CAPACITY];
static int s_scroll_count;
static queued_task_t s_tasks[TEST_CAPACITY];
static int s_task_count;

static bool s_picker_visible;
static bool s_picker_current;
static char s_picker_selected_id[64];
static char s_last_zone_name[64];
static char s_last_message[64];

static bridge_zone_t s_zones[BRIDGE_CLIENT_MAX_ZONES];
static int s_zone_count;
static char s_current_zone_id[64];
static bool s_visit_succeeds = true;
static bool s_visit_invokes_visitor = true;
static int s_visit_calls;

static bridge_zone_selection_result_t s_selection_result;
static int s_selection_calls;
static char s_selected_zone_id[64];

static controller_command_t s_commands[TEST_CAPACITY];
static int s_command_count;
static bool s_command_result = true;

static int s_picker_count;
static int s_picker_selected;
static char s_picker_names[BRIDGE_CLIENT_MAX_ZONES + 2][64];
static char s_picker_ids[BRIDGE_CLIENT_MAX_ZONES + 2][64];

static void trace(trace_event_t event) {
    assert(s_trace_count < TEST_CAPACITY);
    s_trace[s_trace_count++] = event;
}

static void drain_tasks(void) {
    int index = 0;
    while (index < s_task_count) {
        queued_task_t task = s_tasks[index++];
        task.fn(task.arg);
    }
    s_task_count = 0;
}

static void reset_state(void) {
    assert(s_task_count == 0);
    memset(s_trace, 0, sizeof(s_trace));
    memset(s_scroll_values, 0, sizeof(s_scroll_values));
    memset(s_zones, 0, sizeof(s_zones));
    memset(&s_selection_result, 0, sizeof(s_selection_result));
    memset(s_commands, 0, sizeof(s_commands));
    memset(s_picker_names, 0, sizeof(s_picker_names));
    memset(s_picker_ids, 0, sizeof(s_picker_ids));
    s_trace_count = 0;
    s_scroll_count = 0;
    s_picker_visible = false;
    s_picker_current = false;
    s_picker_selected_id[0] = '\0';
    s_last_zone_name[0] = '\0';
    s_last_message[0] = '\0';
    s_zone_count = 0;
    s_current_zone_id[0] = '\0';
    s_visit_succeeds = true;
    s_visit_invokes_visitor = true;
    s_visit_calls = 0;
    s_selection_calls = 0;
    s_selected_zone_id[0] = '\0';
    s_command_count = 0;
    s_command_result = true;
    s_picker_count = 0;
    s_picker_selected = -1;
}

bool platform_task_post_to_ui(platform_task_fn_t fn, void *arg) {
    assert(fn);
    assert(s_task_count < TEST_CAPACITY);
    s_tasks[s_task_count++] = (queued_task_t){.fn = fn, .arg = arg};
    return true;
}

bool bridge_client_execute_command(const controller_command_t *command) {
    assert(command);
    assert(s_command_count < TEST_CAPACITY);
    s_commands[s_command_count++] = *command;
    return s_command_result;
}

bool bridge_client_visit_zones(bridge_zone_list_visitor_t visitor, void *ctx) {
    s_visit_calls++;
    if (!s_visit_succeeds) {
        return false;
    }
    if (s_visit_invokes_visitor) {
        assert(visitor);
        visitor(s_zones, s_zone_count, s_current_zone_id, ctx);
    }
    return true;
}

bridge_zone_selection_result_t bridge_client_select_zone_value(
    const char *zone_id) {
    s_selection_calls++;
    snprintf(s_selected_zone_id, sizeof(s_selected_zone_id), "%s",
             zone_id ? zone_id : "");
    return s_selection_result;
}

bool controller_presentation_is_zone_picker_visible(void) {
    return s_picker_visible;
}

void controller_presentation_zone_picker_scroll(int delta) {
    trace(TRACE_SCROLL);
    assert(s_scroll_count < TEST_CAPACITY);
    s_scroll_values[s_scroll_count++] = delta;
}

void controller_presentation_zone_picker_get_selected_id(char *out,
                                                         size_t len) {
    if (!out || len == 0) {
        return;
    }
    snprintf(out, len, "%s", s_picker_selected_id);
}

bool controller_presentation_zone_picker_is_current_selection(void) {
    return s_picker_current;
}

void controller_presentation_show_zone_picker(const char **zone_names,
                                              const char **zone_ids,
                                              int zone_count,
                                              int selected_idx) {
    trace(TRACE_SHOW_PICKER);
    assert(zone_count >= 0);
    assert(zone_count <= BRIDGE_CLIENT_MAX_ZONES + 2);
    s_picker_count = zone_count;
    s_picker_selected = selected_idx;
    for (int i = 0; i < zone_count; ++i) {
        snprintf(s_picker_names[i], sizeof(s_picker_names[i]), "%s",
                 zone_names[i]);
        snprintf(s_picker_ids[i], sizeof(s_picker_ids[i]), "%s",
                 zone_ids[i]);
    }
}

void controller_presentation_hide_zone_picker(void) {
    trace(TRACE_HIDE_PICKER);
}

void controller_presentation_show_settings(void) {
    trace(TRACE_SHOW_SETTINGS);
}

void controller_presentation_set_zone_name(const char *zone_name) {
    trace(TRACE_ZONE_NAME);
    snprintf(s_last_zone_name, sizeof(s_last_zone_name), "%s",
             zone_name ? zone_name : "");
}

void controller_presentation_set_network_status(const char *status) {
    assert(status == NULL);
    trace(TRACE_NETWORK_STATUS);
}

void controller_presentation_set_message(const char *msg) {
    trace(TRACE_MESSAGE);
    snprintf(s_last_message, sizeof(s_last_message), "%s", msg ? msg : "");
}

static void assert_command(int index,
                           controller_command_kind_t kind,
                           int32_t volume_steps) {
    assert(index >= 0 && index < s_command_count);
    assert(s_commands[index].kind == kind);
    assert(s_commands[index].volume_steps == volume_steps);
}

static void test_non_picker_action_mapping(void) {
    reset_state();

    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PLAY_PAUSE);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_NEXT_TRACK);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PREV_TRACK);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_VOL_UP);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_VOL_DOWN);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_NONE);
    controller_legacy_binding_handle_action((controller_input_action_t)999);

    assert(s_command_count == 5);
    assert_command(0, CONTROLLER_COMMAND_TOGGLE_PLAYBACK, 0);
    assert_command(1, CONTROLLER_COMMAND_NEXT_TRACK, 0);
    assert_command(2, CONTROLLER_COMMAND_PREVIOUS_TRACK, 0);
    assert_command(3, CONTROLLER_COMMAND_ADJUST_VOLUME_STEPS, 1);
    assert_command(4, CONTROLLER_COMMAND_ADJUST_VOLUME_STEPS, -1);
    assert(s_trace_count == 0);
}

static void test_rotation_velocity_mapping(void) {
    reset_state();

    const int ticks[] = {0, 1, -1, 2, -2, 3, -3, 99, -99, INT_MIN};
    const int expected[] = {1, -1, 3, -3, 5, -5, 5, -5, -5};
    for (size_t i = 0; i < sizeof(ticks) / sizeof(ticks[0]); ++i) {
        controller_legacy_binding_handle_rotation(ticks[i]);
    }

    assert(s_command_count == 9);
    for (int i = 0; i < s_command_count; ++i) {
        assert_command(i, CONTROLLER_COMMAND_ADJUST_VOLUME_STEPS, expected[i]);
    }
}

static void test_picker_scroll_and_ignored_inputs(void) {
    reset_state();
    s_picker_visible = true;

    controller_legacy_binding_handle_rotation(2);
    controller_legacy_binding_handle_rotation(-3);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_VOL_UP);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_VOL_DOWN);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_NEXT_TRACK);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PREV_TRACK);
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_NONE);
    controller_legacy_binding_handle_action((controller_input_action_t)999);

    assert(s_command_count == 0);
    assert(s_scroll_count == 4);
    assert(s_scroll_values[0] == 1);
    assert(s_scroll_values[1] == -1);
    assert(s_scroll_values[2] == 1);
    assert(s_scroll_values[3] == -1);
}

static void test_picker_back_settings_current_and_menu(void) {
    reset_state();
    s_picker_visible = true;

    snprintf(s_picker_selected_id, sizeof(s_picker_selected_id), "%s",
             "__back__");
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PLAY_PAUSE);
    assert(s_trace_count == 1);
    assert(s_trace[0] == TRACE_HIDE_PICKER);
    assert(s_selection_calls == 0);

    reset_state();
    s_picker_visible = true;
    snprintf(s_picker_selected_id, sizeof(s_picker_selected_id), "%s",
             "__settings__");
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PLAY_PAUSE);
    assert(s_trace_count == 2);
    assert(s_trace[0] == TRACE_HIDE_PICKER);
    assert(s_trace[1] == TRACE_SHOW_SETTINGS);
    assert(s_selection_calls == 0);

    reset_state();
    s_picker_visible = true;
    s_picker_current = true;
    snprintf(s_picker_selected_id, sizeof(s_picker_selected_id), "%s",
             "zone-current");
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PLAY_PAUSE);
    assert(s_trace_count == 1);
    assert(s_trace[0] == TRACE_HIDE_PICKER);
    assert(s_selection_calls == 0);

    reset_state();
    s_picker_visible = true;
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_MENU);
    assert(s_trace_count == 1);
    assert(s_trace[0] == TRACE_HIDE_PICKER);
    assert(s_visit_calls == 0);
}

static void assert_found_selection(bool persisted, bool became_operational) {
    reset_state();
    s_picker_visible = true;
    snprintf(s_picker_selected_id, sizeof(s_picker_selected_id), "%s",
             "zone-kitchen");
    s_selection_result.found = true;
    s_selection_result.persisted = persisted;
    s_selection_result.became_operational = became_operational;
    snprintf(s_selection_result.zone_name,
             sizeof(s_selection_result.zone_name), "%s", "Kitchen");

    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PLAY_PAUSE);

    assert(s_selection_calls == 1);
    assert(strcmp(s_selected_zone_id, "zone-kitchen") == 0);
    assert(s_trace_count == (became_operational ? 2 : 1));
    if (became_operational) {
        assert(s_trace[0] == TRACE_NETWORK_STATUS);
        assert(s_trace[1] == TRACE_HIDE_PICKER);
    } else {
        assert(s_trace[0] == TRACE_HIDE_PICKER);
    }
    assert(s_task_count == 2);

    drain_tasks();
    int zone_trace = became_operational ? 2 : 1;
    assert(s_trace_count == zone_trace + 2);
    assert(s_trace[zone_trace] == TRACE_ZONE_NAME);
    assert(s_trace[zone_trace + 1] == TRACE_MESSAGE);
    assert(strcmp(s_last_zone_name, "Kitchen") == 0);
    assert(strcmp(s_last_message, "Loading zone...") == 0);
}

static void test_picker_selection_results(void) {
    assert_found_selection(true, true);
    assert_found_selection(true, false);
    assert_found_selection(false, true);
    assert_found_selection(false, false);

    reset_state();
    s_picker_visible = true;
    snprintf(s_picker_selected_id, sizeof(s_picker_selected_id), "%s",
             "missing");
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_PLAY_PAUSE);
    assert(s_selection_calls == 1);
    assert(s_trace_count == 1);
    assert(s_trace[0] == TRACE_HIDE_PICKER);
    assert(s_task_count == 0);
}

static void test_menu_zone_list(void) {
    reset_state();
    s_zone_count = 2;
    snprintf(s_zones[0].id, sizeof(s_zones[0].id), "%s", "zone-one");
    snprintf(s_zones[0].name, sizeof(s_zones[0].name), "%s", "Living");
    snprintf(s_zones[1].id, sizeof(s_zones[1].id), "%s", "zone-two");
    snprintf(s_zones[1].name, sizeof(s_zones[1].name), "%s", "Kitchen");
    snprintf(s_current_zone_id, sizeof(s_current_zone_id), "%s", "zone-two");

    controller_legacy_binding_handle_action(CONTROLLER_INPUT_MENU);

    assert(s_visit_calls == 1);
    assert(s_trace_count == 1);
    assert(s_trace[0] == TRACE_SHOW_PICKER);
    assert(s_picker_count == 4);
    assert(s_picker_selected == 2);
    assert(strcmp(s_picker_names[0], "Back") == 0);
    assert(strcmp(s_picker_ids[0], "__back__") == 0);
    assert(strcmp(s_picker_names[1], "Living") == 0);
    assert(strcmp(s_picker_ids[1], "zone-one") == 0);
    assert(strcmp(s_picker_names[2], "Kitchen") == 0);
    assert(strcmp(s_picker_ids[2], "zone-two") == 0);
    assert(strcmp(s_picker_names[3], "Settings") == 0);
    assert(strcmp(s_picker_ids[3], "__settings__") == 0);

    reset_state();
    s_visit_succeeds = false;
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_MENU);
    assert(s_visit_calls == 1);
    assert(s_picker_count == 2);
    assert(s_picker_selected == 1);
    assert(strcmp(s_picker_ids[0], "__back__") == 0);
    assert(strcmp(s_picker_ids[1], "__settings__") == 0);

    reset_state();
    s_visit_invokes_visitor = false;
    controller_legacy_binding_handle_action(CONTROLLER_INPUT_MENU);
    assert(s_visit_calls == 1);
    assert(s_picker_count == 2);
    assert(s_picker_selected == 1);
}

int main(void) {
    test_non_picker_action_mapping();
    test_rotation_velocity_mapping();
    test_picker_scroll_and_ignored_inputs();
    test_picker_back_settings_current_and_menu();
    test_picker_selection_results();
    test_menu_zone_list();
    puts("controller legacy binding contracts passed");
    return 0;
}
