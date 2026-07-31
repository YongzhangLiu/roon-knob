idf_component_register(
    SRCS
        "${CMAKE_CURRENT_LIST_DIR}/../rk_ble_hid_host/rk_ble_hid_host_stub.c"
        "${CMAKE_CURRENT_LIST_DIR}/../rk_ble_hid_host/rk_ble_hid_report.c"
    INCLUDE_DIRS
        "${CMAKE_CURRENT_LIST_DIR}/../rk_ble_hid_host/include"
)

set_property(TARGET ${COMPONENT_LIB} PROPERTY C_STANDARD 11)
