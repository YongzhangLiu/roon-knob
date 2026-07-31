#include "controller_legacy_binding.h"

#include "bridge_client.h"
#include "controller_command.h"
#include "controller_presentation.h"
#include "platform/platform_task.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ZONE_ID_BACK "__back__"
#define ZONE_ID_SETTINGS "__settings__"

static const char *const s_back_name = "Back";
static const char *const s_back_id = ZONE_ID_BACK;
static const char *const s_settings_name = "Settings";
static const char *const s_settings_id = ZONE_ID_SETTINGS;

typedef void (*queued_text_setter_t)(const char *text);

typedef struct {
    queued_text_setter_t setter;
    char text[];
} queued_text_t;

static void apply_queued_text(void *arg) {
    queued_text_t *queued = arg;
    if (!queued) {
        return;
    }
    queued->setter(queued->text);
    free(queued);
}

static void post_text(queued_text_setter_t setter, const char *text) {
    if (!setter || !text) {
        return;
    }

    size_t text_len = strlen(text);
    queued_text_t *queued = malloc(sizeof(*queued) + text_len + 1);
    if (!queued) {
        return;
    }
    queued->setter = setter;
    memcpy(queued->text, text, text_len + 1);

    if (!platform_task_post_to_ui(apply_queued_text, queued)) {
        free(queued);
    }
}

static void submit_simple_command(controller_command_kind_t kind) {
    controller_command_t command = controller_command_make(kind);
    (void)bridge_client_execute_command(&command);
}

static void submit_volume_steps(int32_t signed_steps) {
    controller_command_t command =
        controller_command_adjust_volume(signed_steps);
    (void)bridge_client_execute_command(&command);
}

typedef struct {
    bool shown;
} picker_open_context_t;

static void show_picker_for_zones(const bridge_zone_t *zones,
                                  int zone_count,
                                  const char *current_zone_id,
                                  void *ctx) {
    picker_open_context_t *open = ctx;
    const char *names[BRIDGE_CLIENT_MAX_ZONES + 2];
    const char *ids[BRIDGE_CLIENT_MAX_ZONES + 2];
    int count = 0;
    int selected = 1;

    names[count] = s_back_name;
    ids[count] = s_back_id;
    count++;

    if (!zones || zone_count < 0) {
        zone_count = 0;
    }
    if (zone_count > BRIDGE_CLIENT_MAX_ZONES) {
        zone_count = BRIDGE_CLIENT_MAX_ZONES;
    }

    for (int i = 0; i < zone_count; ++i) {
        names[count] = zones[i].name;
        ids[count] = zones[i].id;
        if (current_zone_id &&
            strcmp(zones[i].id, current_zone_id) == 0) {
            selected = count;
        }
        count++;
    }

    names[count] = s_settings_name;
    ids[count] = s_settings_id;
    count++;

    controller_presentation_show_zone_picker(names, ids, count, selected);
    if (open) {
        open->shown = true;
    }
}

static void open_picker(void) {
    picker_open_context_t open = {0};
    bool visited = bridge_client_visit_zones(show_picker_for_zones, &open);
    if (!visited || !open.shown) {
        show_picker_for_zones(NULL, 0, NULL, &open);
    }
}

static void select_picker_entry(void) {
    char selected_id[sizeof(((bridge_zone_t *)0)->id)] = {0};
    controller_presentation_zone_picker_get_selected_id(
        selected_id, sizeof(selected_id));

    if (strcmp(selected_id, ZONE_ID_BACK) == 0) {
        controller_presentation_hide_zone_picker();
        return;
    }

    if (strcmp(selected_id, ZONE_ID_SETTINGS) == 0) {
        controller_presentation_hide_zone_picker();
        controller_presentation_show_settings();
        return;
    }

    if (controller_presentation_zone_picker_is_current_selection()) {
        controller_presentation_hide_zone_picker();
        return;
    }

    bridge_zone_selection_result_t result =
        bridge_client_select_zone_value(selected_id);
    if (result.found && result.became_operational) {
        /*
         * Preserve the old transition-only clear before closing the picker.
         * An operational controller may still have a useful retry banner that
         * a zone switch must not hide.
         */
        controller_presentation_set_network_status(NULL);
    }
    controller_presentation_hide_zone_picker();
    if (!result.found) {
        return;
    }

    /*
     * Preserve the legacy picker behavior: once a zone is found, update the
     * UI even if persisting the selection failed. The web wrapper continues
     * to use result.persisted as its failure contract.
     */
    post_text(controller_presentation_set_zone_name, result.zone_name);
    post_text(controller_presentation_set_message, "Loading zone...");
}

void controller_legacy_binding_handle_action(controller_input_action_t action) {
    if (controller_presentation_is_zone_picker_visible()) {
        switch (action) {
        case CONTROLLER_INPUT_VOL_UP:
            controller_presentation_zone_picker_scroll(1);
            return;
        case CONTROLLER_INPUT_VOL_DOWN:
            controller_presentation_zone_picker_scroll(-1);
            return;
        case CONTROLLER_INPUT_PLAY_PAUSE:
            select_picker_entry();
            return;
        case CONTROLLER_INPUT_MENU:
            controller_presentation_hide_zone_picker();
            return;
        case CONTROLLER_INPUT_NONE:
        case CONTROLLER_INPUT_NEXT_TRACK:
        case CONTROLLER_INPUT_PREV_TRACK:
        default:
            return;
        }
    }

    switch (action) {
    case CONTROLLER_INPUT_VOL_DOWN:
        submit_volume_steps(-1);
        break;
    case CONTROLLER_INPUT_VOL_UP:
        submit_volume_steps(1);
        break;
    case CONTROLLER_INPUT_PLAY_PAUSE:
        submit_simple_command(CONTROLLER_COMMAND_TOGGLE_PLAYBACK);
        break;
    case CONTROLLER_INPUT_MENU:
        open_picker();
        break;
    case CONTROLLER_INPUT_NEXT_TRACK:
        submit_simple_command(CONTROLLER_COMMAND_NEXT_TRACK);
        break;
    case CONTROLLER_INPUT_PREV_TRACK:
        submit_simple_command(CONTROLLER_COMMAND_PREVIOUS_TRACK);
        break;
    case CONTROLLER_INPUT_NONE:
    default:
        break;
    }
}

void controller_legacy_binding_handle_rotation(int ticks) {
    if (ticks == 0) {
        return;
    }

    if (controller_presentation_is_zone_picker_visible()) {
        controller_presentation_zone_picker_scroll(ticks > 0 ? 1 : -1);
        return;
    }

    int64_t magnitude = ticks;
    if (magnitude < 0) {
        magnitude = -magnitude;
    }

    int32_t steps;
    if (magnitude >= 3) {
        steps = 5;
    } else if (magnitude == 2) {
        steps = 3;
    } else {
        steps = 1;
    }
    submit_volume_steps(ticks > 0 ? steps : -steps);
}
