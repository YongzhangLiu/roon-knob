# ESP-IDF 5.5.5's NimBLE HID host blocks some media remotes while enabling
# optional Battery Service notifications, before it reaches the HID report
# CCCDs. It also retains ownership of successful read buffers after returning
# them to its caller, which makes deinit free the caller-freed buffer again.
#
# Keep the upstream component pinned by the workflow, generate one patched
# translation unit, and fail configuration if the expected upstream source
# changes. All other esp_hid sources and headers remain the IDF implementation.

idf_build_get_property(target IDF_TARGET)

if(${target} STREQUAL "linux")
    return()
endif()

set(upstream_dir "${IDF_PATH}/components/esp_hid")
set(upstream_nimble_hidh "${upstream_dir}/src/nimble_hidh.c")
file(READ "${upstream_nimble_hidh}" nimble_hidh_source)

set(read_transfer_before
"        *out = s_read_data_val;
        *out_len = s_read_data_len;")
set(read_transfer_after
"        *out = s_read_data_val;
        *out_len = s_read_data_len;
        /* Ownership moved to the caller; deinit must not free it again. */
        s_read_data_val = NULL;
        s_read_data_len = 0;")
string(FIND "${nimble_hidh_source}" "${read_transfer_before}"
       first_read_transfer_offset)
if(first_read_transfer_offset EQUAL -1)
    message(FATAL_ERROR
            "ESP-IDF NimBLE HID read ownership transfer no longer matches the pinned override")
endif()
string(REPLACE "${read_transfer_before}" "${read_transfer_after}"
       nimble_hidh_source "${nimble_hidh_source}")

set(battery_notify_before
"        register_for_notify(dev->ble.conn_id, dev->ble.battery_handle);
        if (dev->ble.battery_ccc_handle && dev->ble.conn_id >= 0 && dev->connected) {
            write_char_descr(dev, dev->ble.battery_ccc_handle, 2, (uint8_t *)&ccc_data);
        }")
set(battery_notify_after
"        /* Battery telemetry is optional for this one-remote media profile.
         * Some remotes never answer this CCCD write, which otherwise blocks
         * esp_hidh_dev_open() before HID input reports are subscribed. */
        ESP_LOGI(TAG, \"Skipping optional Battery Service notification subscription\");")
string(FIND "${nimble_hidh_source}" "${battery_notify_before}"
       battery_notify_offset)
if(battery_notify_offset EQUAL -1)
    message(FATAL_ERROR
            "ESP-IDF NimBLE HID battery subscription block no longer matches the pinned override")
endif()
string(REPLACE "${battery_notify_before}" "${battery_notify_after}"
       nimble_hidh_source "${nimble_hidh_source}")

set(generated_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${generated_dir}")
file(WRITE "${generated_dir}/nimble_hidh.c" "${nimble_hidh_source}")

set(srcs "${upstream_dir}/src/esp_hidd.c"
         "${upstream_dir}/src/esp_hidh.c"
         "${upstream_dir}/src/esp_hid_common.c")

if(CONFIG_BT_ENABLED)
    if(CONFIG_BT_BLUEDROID_ENABLED)
        list(APPEND srcs
             "${upstream_dir}/src/ble_hidd.c"
             "${upstream_dir}/src/ble_hidh.c"
             "${upstream_dir}/src/bt_hidh.c"
             "${upstream_dir}/src/bt_hidd.c")
    endif()
    if(CONFIG_BT_NIMBLE_ENABLED)
        list(APPEND srcs
             "${upstream_dir}/src/nimble_hidd.c"
             "${generated_dir}/nimble_hidh.c")
    endif()
endif()

idf_component_register(SRCS "${srcs}"
                       INCLUDE_DIRS "${upstream_dir}/include"
                       PRIV_INCLUDE_DIRS "${upstream_dir}/private"
                       REQUIRES esp_event bt)

target_compile_options(${COMPONENT_LIB} PRIVATE "-Wno-format")
