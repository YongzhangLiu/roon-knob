// HTTP config server - runs when connected to WiFi for remote configuration
// Access at http://<knob-ip>/ to set bridge URL

#include "config_server.h"
#include "platform/platform_storage.h"
#include "platform/platform_mdns.h"
#include "bridge_client.h"
#include "wifi_manager.h"

#include <stdlib.h>
#include <string.h>
#include <esp_log.h>
#include <esp_http_server.h>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

static const char *TAG = "config_server";

static httpd_handle_t s_server = NULL;

// HTML page for config
// Format args: current_bridge, status_class, status_text, wifi_html, bridge_value
static const char *HTML_CONFIG =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>Roon Knob Config</title>"
    "<style>"
    "body{font-family:sans-serif;margin:20px;background:#1a1a2e;color:#eee;}"
    "h1{color:#4fc3f7;margin-bottom:5px;}"
    "h2{color:#aaa;font-size:16px;margin-top:20px;}"
    ".info{color:#888;margin:10px 0;}"
    "form{background:#16213e;padding:20px;border-radius:10px;max-width:400px;}"
    "label{display:block;margin:15px 0 5px;color:#aaa;}"
    "input[type=text],input[type=url],input[type=password]{width:100%%;padding:10px;border:1px solid #333;border-radius:5px;background:#0f0f1a;color:#fff;box-sizing:border-box;}"
    "input[type=submit]{padding:12px 24px;margin-top:20px;background:#4fc3f7;color:#000;border:none;border-radius:5px;font-weight:bold;cursor:pointer;}"
    "input[type=submit]:hover{background:#29b6f6;}"
    ".btn-clear{background:#ff7043;}"
    ".btn-clear:hover{background:#ff5722;}"
    ".btn-sm{padding:6px 12px;margin:0 0 0 10px;font-size:12px;}"
    ".current{background:#0f0f1a;padding:10px;border-radius:5px;margin:10px 0;font-family:monospace;}"
    ".status{padding:10px;border-radius:5px;margin:10px 0;}"
    ".status-ok{background:#1b5e20;}"
    ".status-warn{background:#e65100;}"
    ".status-err{background:#b71c1c;}"
    ".hint{font-size:12px;color:#666;margin-top:4px;}"
    ".success{background:#2e7d32;padding:15px;border-radius:5px;margin:15px 0;}"
    ".wifi-entry{background:#0f0f1a;padding:8px 12px;border-radius:5px;margin:4px 0;display:flex;justify-content:space-between;align-items:center;max-width:400px;}"
    ".section{max-width:400px;}"
    "</style></head><body>"
    "<h1>Roon Knob</h1>"
    "<p class='info'>Configure your Roon Knob settings</p>"
    "<div class='current'>"
    "<strong>Current Bridge:</strong> %s"
    "</div>"
    "<div class='status %s'>"
    "<strong>Status:</strong> %s"
    "</div>"
        "<h2>Saved WiFi Networks</h2>"
        "<div class='section'>%s</div>"
        "<p class='hint'>Saved-network changes take effect after restart.</p>"
    "<form method='POST' action='/wifi-add'>"
    "<h2>Add WiFi Network</h2>"
    "<label>SSID</label>"
    "<input type='text' name='ssid' maxlength='32' placeholder='Network name' required>"
    "<label>Password</label>"
        "<input type='password' name='pass' maxlength='64' placeholder='Password (optional)'>"
        "<p class='hint'>Up to two networks. Remove one before replacing it.</p>"
    "<input type='submit' value='Add Network'>"
    "</form>"
    "<form method='POST' action='/config'>"
    "<h2>Bridge Override</h2>"
    "<label>Bridge URL</label>"
    "<input type='url' name='bridge' maxlength='128' placeholder='http://192.168.1.x:8088' value='%s'>"
    "<p class='hint'>Leave empty for mDNS auto-discovery. Check the Roon Knob display for connection progress.</p>"
    "<input type='submit' value='Save'>"
    "<input type='submit' name='action' value='Clear' class='btn-clear' formnovalidate>"
    "</form></body></html>";

static const char *HTML_SUCCESS =
    "<!DOCTYPE html>"
    "<html><head>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'>"
    "<title>Saved</title>"
    "<style>"
    "body{font-family:sans-serif;margin:20px;background:#1a1a2e;color:#eee;text-align:center;}"
    "h1{color:#4fc3f7;}"
    ".success{background:#2e7d32;padding:20px;border-radius:10px;max-width:300px;margin:20px auto;}"
    ".info{background:#16213e;padding:15px;border-radius:10px;max-width:300px;margin:20px auto;}"
    "</style></head><body>"
    "<h1>Roon Knob</h1>"
    "<div class='success'>%s</div>"
    "<div class='info'>Device will reboot automatically to apply changes...</div>"
    "</body></html>";

// URL decode a string in place
static void url_decode(char *str) {
    char *src = str;
    char *dst = str;
    while (*src) {
        if (*src == '+') {
            *dst++ = ' ';
            src++;
        } else if (*src == '%' && src[1] && src[2]) {
            char hex[3] = {src[1], src[2], 0};
            *dst++ = (char)strtol(hex, NULL, 16);
            src += 3;
        } else {
            *dst++ = *src++;
        }
    }
    *dst = '\0';
}

// Parse form data to extract a field value
static bool get_form_field(const char *data, const char *field, char *out, size_t out_len) {
    char search[64];
    snprintf(search, sizeof(search), "%s=", field);

    const char *start = data;
    while ((start = strstr(start, search)) != NULL) {
        if (start == data || *(start - 1) == '&') {
            break;
        }
        start++;
    }
    if (!start) {
        return false;
    }
    start += strlen(search);

    const char *end = strchr(start, '&');
    size_t len = end ? (size_t)(end - start) : strlen(start);

    // URL-encoded data can be up to 3x the decoded length (e.g. ! -> %21).
    // Decode in a temporary buffer first, then truncate to fit the output.
    char encoded[256];
    if (len >= sizeof(encoded)) {
        len = sizeof(encoded) - 1;
    }

    memcpy(encoded, start, len);
    encoded[len] = '\0';
    url_decode(encoded);

    size_t decoded_len = strlen(encoded);
    if (decoded_len >= out_len) {
        decoded_len = out_len - 1;
    }
    memcpy(out, encoded, decoded_len);
    out[decoded_len] = '\0';
    return true;
}

static void html_escape(const char *src, char *dst, size_t dst_len) {
    size_t pos = 0;
    for (size_t i = 0; src && src[i] && pos + 1 < dst_len; i++) {
        const char *escaped = NULL;
        switch (src[i]) {
            case '&': escaped = "&amp;"; break;
            case '<': escaped = "&lt;"; break;
            case '>': escaped = "&gt;"; break;
            case '"': escaped = "&quot;"; break;
            case '\'': escaped = "&#39;"; break;
            default: break;
        }
        if (escaped) {
            size_t len = strlen(escaped);
            if (pos + len >= dst_len) break;
            memcpy(dst + pos, escaped, len);
            pos += len;
        } else {
            dst[pos++] = src[i];
        }
    }
    dst[pos] = '\0';
}

// Resolve .local hostname in URL to IP address via mDNS
// Modifies url in place if resolution succeeds
static void resolve_local_in_url(char *url, size_t url_len) {
    if (!url || !url[0]) return;

    // Check if URL contains .local
    char *local_pos = strstr(url, ".local");
    if (!local_pos) return;

    // Make sure it's actually the hostname suffix (followed by : or / or end)
    char after = local_pos[6];
    if (after != ':' && after != '/' && after != '\0') return;

    // Extract hostname: skip http://
    const char *host_start = strstr(url, "://");
    if (!host_start) return;
    host_start += 3;

    // Find end of hostname
    const char *host_end = host_start;
    while (*host_end && *host_end != ':' && *host_end != '/') host_end++;

    // Extract hostname
    size_t host_len = host_end - host_start;
    if (host_len == 0 || host_len >= 64) return;

    char hostname[64];
    memcpy(hostname, host_start, host_len);
    hostname[host_len] = '\0';

    // Resolve via mDNS
    char ip[16];
    if (!platform_mdns_resolve_local(hostname, ip, sizeof(ip))) {
        ESP_LOGW(TAG, "Could not resolve %s via mDNS", hostname);
        return;
    }

    // Build new URL with IP instead of hostname
    char new_url[128];
    size_t scheme_len = host_start - url;
    snprintf(new_url, sizeof(new_url), "%.*s%s%s", (int)scheme_len, url, ip, host_end);

    // Copy back if it fits
    if (strlen(new_url) < url_len) {
        strcpy(url, new_url);
        ESP_LOGI(TAG, "Resolved .local URL to: %s", url);
    }
}

// Handler for GET / - serve the config form
static esp_err_t config_get_handler(httpd_req_t *req) {
    ESP_LOGI(TAG, "Serving config page");

    rk_cfg_t cfg = {0};
    platform_storage_load(&cfg);

    const char *current = cfg.bridge_base[0] ? cfg.bridge_base : "(mDNS auto-discovery)";

    // Get bridge connection status
    const char *status_class;
    char status_text[64];
    bool bridge_connected = bridge_client_is_bridge_connected();
    int retry_count = bridge_client_get_bridge_retry_count();
    int retry_max = bridge_client_get_bridge_retry_max();

    if (bridge_connected) {
        status_class = "status-ok";
        snprintf(status_text, sizeof(status_text), "Connected");
    } else if (!cfg.bridge_base[0]) {
        status_class = "status-warn";
        snprintf(status_text, sizeof(status_text), "Searching via mDNS...");
    } else if (retry_count >= retry_max) {
        status_class = "status-err";
        snprintf(status_text, sizeof(status_text), "Unreachable - check URL or bridge server");
    } else if (retry_count > 0) {
        status_class = "status-warn";
        snprintf(status_text, sizeof(status_text), "Connecting... (%d/%d)", retry_count, retry_max);
    } else {
        status_class = "status-warn";
        snprintf(status_text, sizeof(status_text), "Connecting...");
    }

    char wifi_html[1024] = "";
    size_t wifi_pos = 0;
    for (int i = 0; i < cfg.wifi_count && i < RK_MAX_WIFI; i++) {
        char escaped_ssid[192];
        html_escape(cfg.wifi[i].ssid, escaped_ssid, sizeof(escaped_ssid));
        int written = snprintf(
            wifi_html + wifi_pos, sizeof(wifi_html) - wifi_pos,
            "<div class='wifi-entry'><span>%d. %s</span>"
            "<form method='POST' action='/wifi-remove' style='display:inline;margin:0;padding:0;'>"
            "<input type='hidden' name='idx' value='%d'>"
            "<input type='submit' value='Remove' class='btn-sm btn-clear'>"
            "</form></div>",
            i + 1, escaped_ssid, i);
        if (written < 0 || (size_t)written >= sizeof(wifi_html) - wifi_pos) {
            break;
        }
        wifi_pos += (size_t)written;
    }
    if (wifi_pos == 0) {
        snprintf(wifi_html, sizeof(wifi_html),
                 "<div class='wifi-entry'><em>No saved networks</em></div>");
    }

    // Build HTML with current values, saved networks, and bridge status.
    char *html = malloc(4096);
    if (!html) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Out of memory");
        return ESP_FAIL;
    }

    snprintf(html, 4096, HTML_CONFIG, current, status_class, status_text,
             wifi_html, cfg.bridge_base);

    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, html, strlen(html));
    free(html);
    return ESP_OK;
}

// Handler for POST /config - save settings
static esp_err_t config_post_handler(httpd_req_t *req) {
    char buf[256] = {0};
    int received = httpd_req_recv(req, buf, sizeof(buf) - 1);

    if (received <= 0) {
        ESP_LOGE(TAG, "Failed to receive POST data");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "No data received");
        return ESP_FAIL;
    }
    buf[received] = '\0';
    ESP_LOGI(TAG, "Received config: %s", buf);

    rk_cfg_t cfg = {0};
    platform_storage_load(&cfg);

    // Check if Clear button was pressed
    char action[16] = {0};
    get_form_field(buf, "action", action, sizeof(action));

    const char *message;
    if (strcmp(action, "Clear") == 0) {
        cfg.bridge_base[0] = '\0';
        cfg.bridge_from_mdns = 0;  // Will be set when mDNS discovers
        message = "Bridge cleared! Will use mDNS.";
        ESP_LOGI(TAG, "Bridge URL cleared");
    } else {
        char bridge[129] = {0};
        get_form_field(buf, "bridge", bridge, sizeof(bridge));

        // Validate bridge URL format if provided
        if (bridge[0] && strncmp(bridge, "http://", 7) != 0) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                "Invalid URL. Must start with http://");
            return ESP_FAIL;
        }

        strncpy(cfg.bridge_base, bridge, sizeof(cfg.bridge_base) - 1);

        // Resolve .local hostnames to IPs (ESP32 lwIP has issues with .local DNS)
        if (bridge[0]) {
            resolve_local_in_url(cfg.bridge_base, sizeof(cfg.bridge_base));
            cfg.bridge_from_mdns = 0;  // Manually configured
        } else {
            cfg.bridge_from_mdns = 0;  // Will be set when mDNS discovers
        }

        message = cfg.bridge_base[0] ? "Bridge URL saved!" : "Bridge cleared! Will use mDNS.";
        ESP_LOGI(TAG, "Bridge URL set to: %s", cfg.bridge_base[0] ? cfg.bridge_base : "(mDNS)");
    }

    if (!bridge_client_store_bridge_base(cfg.bridge_base,
                                         cfg.bridge_from_mdns != 0)) {
        ESP_LOGE(TAG, "Failed to save config");
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to save");
        return ESP_FAIL;
    }

    // Send success response
    char *html = malloc(1024);
    if (!html) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Out of memory");
        return ESP_FAIL;
    }

    snprintf(html, 1024, HTML_SUCCESS, message);
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, html, strlen(html));
    free(html);

    // Reboot to apply new config
    ESP_LOGI(TAG, "Config saved, rebooting in 1 second...");
    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();

    return ESP_OK;
}

static esp_err_t wifi_add_handler(httpd_req_t *req) {
    char buf[384] = {0};
    int received = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (received <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "No data received");
        return ESP_FAIL;
    }
    buf[received] = '\0';

    char ssid[33] = {0};
    char pass[65] = {0};
    if (!get_form_field(buf, "ssid", ssid, sizeof(ssid)) || !ssid[0]) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing SSID");
        return ESP_FAIL;
    }
    get_form_field(buf, "pass", pass, sizeof(pass));

    rk_cfg_t cfg = {0};
    platform_storage_load(&cfg);
    if (rk_cfg_add_wifi(&cfg, ssid, pass) < 0) {
        httpd_resp_set_status(req, "409 Conflict");
        httpd_resp_set_type(req, "text/plain");
        httpd_resp_sendstr(req,
                          "Two networks are already saved; remove one first");
        return ESP_FAIL;
    }
    rk_cfg_sync_primary_wifi(&cfg);
    cfg.cfg_ver = RK_CFG_CURRENT_VER;
    if (!bridge_client_store_local_connectivity(&cfg)) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to save");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Added WiFi '%s' to this Dial (%d saved)", ssid,
             cfg.wifi_count);
    httpd_resp_set_status(req, "303 See Other");
    httpd_resp_set_hdr(req, "Location", "/");
    httpd_resp_sendstr(req, "Redirecting...");
    return ESP_OK;
}

static esp_err_t wifi_remove_handler(httpd_req_t *req) {
    char buf[64] = {0};
    int received = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (received <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "No data received");
        return ESP_FAIL;
    }
    buf[received] = '\0';

    char idx_text[8] = {0};
    if (!get_form_field(buf, "idx", idx_text, sizeof(idx_text))) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing index");
        return ESP_FAIL;
    }
    char *end = NULL;
    long parsed = strtol(idx_text, &end, 10);
    if (end == idx_text || *end != '\0' || parsed < 0 || parsed >= RK_MAX_WIFI) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid index");
        return ESP_FAIL;
    }

    rk_cfg_t cfg = {0};
    platform_storage_load(&cfg);
    int idx = (int)parsed;
    if (idx < cfg.wifi_count) {
        ESP_LOGI(TAG, "Removing WiFi '%s' from this Dial", cfg.wifi[idx].ssid);
        rk_cfg_remove_wifi(&cfg, idx);
        rk_cfg_sync_primary_wifi(&cfg);
        if (!bridge_client_store_local_connectivity(&cfg)) {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                                "Failed to save");
            return ESP_FAIL;
        }
    }

    httpd_resp_set_status(req, "303 See Other");
    httpd_resp_set_hdr(req, "Location", "/");
    httpd_resp_sendstr(req, "Redirecting...");
    return ESP_OK;
}

void config_server_start(void) {
    if (s_server) {
        ESP_LOGW(TAG, "Config server already running");
        return;
    }

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 80;
    config.max_uri_handlers = 8;
    config.stack_size = 8192;  // Increased for mDNS resolution during config save
    // Note: max_req_hdr_len set via CONFIG_HTTPD_MAX_REQ_HDR_LEN in sdkconfig

    ESP_LOGI(TAG, "Starting config server on port %d", config.server_port);

    if (httpd_start(&s_server, &config) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server");
        return;
    }

    // Register URI handlers
    httpd_uri_t root = {
        .uri = "/",
        .method = HTTP_GET,
        .handler = config_get_handler,
    };
    httpd_register_uri_handler(s_server, &root);

    httpd_uri_t config_post = {
        .uri = "/config",
        .method = HTTP_POST,
        .handler = config_post_handler,
    };
    httpd_register_uri_handler(s_server, &config_post);

    httpd_uri_t wifi_add = {
        .uri = "/wifi-add",
        .method = HTTP_POST,
        .handler = wifi_add_handler,
    };
    httpd_register_uri_handler(s_server, &wifi_add);

    httpd_uri_t wifi_remove = {
        .uri = "/wifi-remove",
        .method = HTTP_POST,
        .handler = wifi_remove_handler,
    };
    httpd_register_uri_handler(s_server, &wifi_remove);

    ESP_LOGI(TAG, "Config server started");
}

void config_server_stop(void) {
    if (!s_server) {
        return;
    }

    ESP_LOGI(TAG, "Stopping config server");
    httpd_stop(s_server);
    s_server = NULL;
}

bool config_server_is_running(void) {
    return s_server != NULL;
}
