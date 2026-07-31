#pragma once

#include "rk_cfg.h"
#include "controller_input.h"
#include <stdbool.h>
#include <stddef.h>

void bridge_client_start(const rk_cfg_t *cfg);
void bridge_client_handle_input(controller_input_action_t event);
void bridge_client_handle_volume_rotation(int ticks);  // Velocity-sensitive volume control
void bridge_client_set_network_ready(bool ready);
const char* bridge_client_get_artwork_url(char *url_buf, size_t buf_len, int width, int height);
const char* bridge_client_get_artwork_url_for_format(char *url_buf, size_t buf_len,
                                                     int width, int height,
                                                     int clip_radius,
                                                     const char *format);
bool bridge_client_is_ready_for_art_mode(void);

// Bridge connection status (mirrors WiFi retry pattern for consistent UX)
void bridge_client_set_device_ip(const char *ip);  // Call when WiFi gets IP
int bridge_client_get_bridge_retry_count(void);    // Current retry attempt (0 = connected)
int bridge_client_get_bridge_retry_max(void);      // Max retries before showing recovery info
bool bridge_client_get_bridge_url(char *buf, size_t len);  // Get configured bridge URL
bool bridge_client_is_bridge_connected(void);      // True if bridge is responding
bool bridge_client_is_bridge_mdns(void);           // True if bridge was discovered via mDNS (persisted)

// Target-neutral zone access used by configuration surfaces that do not render
// the controller's on-device zone picker (for example the Frame web UI).
typedef struct {
    char id[64];
    char name[64];
} bridge_zone_t;

int bridge_client_get_zones(bridge_zone_t *out, int max);
bool bridge_client_get_current_zone_id(char *out, size_t len);
bool bridge_client_set_zone(const char *zone_id);

/**
 * Atomically update and persist only this device's local WiFi fields while
 * preserving the controller/bridge configuration held by the running device.
 */
bool bridge_client_store_local_connectivity(const rk_cfg_t *local_cfg);

/**
 * Atomically update and persist the controller bridge endpoint while
 * preserving this device's connectivity and the remaining controller state.
 */
bool bridge_client_store_bridge_base(const char *bridge_base, bool from_mdns);
