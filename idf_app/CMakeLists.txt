cmake_minimum_required(VERSION 3.16)

# App version (semver) - update this for releases
set(PROJECT_VER "2.2.2")

# Auto-append -dev if not building from a release tag
# CI builds from tags get clean version, local builds get -dev
execute_process(
    COMMAND git describe --exact-match --tags HEAD
    RESULT_VARIABLE NOT_ON_TAG
    OUTPUT_QUIET ERROR_QUIET
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
)
if(NOT_ON_TAG)
    string(APPEND PROJECT_VER "-dev")
endif()

# Suppress CMake warnings (ESP-IDF internal component validation issues)
set(CMAKE_SUPPRESS_DEVELOPER_WARNINGS ON CACHE BOOL "" FORCE)

# --- sdkconfig staleness guard (restored from #149) ---
# Detect when sdkconfig.defaults has changed since the last configure.
# A stale sdkconfig silently ignores new defaults, causing build failures
# (DRAM overflow, missing symbols, wrong optimization level).
#
# Scope, stated honestly (#202): this is a LOCAL developer-ergonomics guard, not a
# release-safety mechanism. It requires BOTH an existing sdkconfig and a stamp file
# in the build dir, so it is silent on a fresh CI checkout, and scripts/install.sh's
# `rm sdkconfig` bypasses it by design. Its release-safety role is superseded by the
# effective-config gate in cmake/rk_release_config.cmake, which fires everywhere
# this guard cannot. It is restored rather than merely superseded because of its one
# non-substitutable contribution: the CMAKE_CONFIGURE_DEPENDS line below, without
# which editing sdkconfig.defaults would not re-run configure at all.
#
# It keeps FATAL_ERROR (unlike the config gate, which defers via
# fail_at_build_time) because its recovery is `rm sdkconfig && idf.py build` and
# does not require menuconfig to still work. The asymmetry is deliberate.
set(_DEFAULTS_FILE "${CMAKE_CURRENT_SOURCE_DIR}/sdkconfig.defaults")
set(_SDKCONFIG "${CMAKE_CURRENT_SOURCE_DIR}/sdkconfig")
set(_STAMP_FILE "${CMAKE_BINARY_DIR}/.sdkconfig_defaults_hash")
if(EXISTS "${_DEFAULTS_FILE}")
    # Ensure CMake reconfigures when defaults change (otherwise idf.py build skips us)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_DEFAULTS_FILE}")
    file(MD5 "${_DEFAULTS_FILE}" _DEFAULTS_HASH)
    if(EXISTS "${_SDKCONFIG}" AND EXISTS "${_STAMP_FILE}")
        file(READ "${_STAMP_FILE}" _PREV_HASH)
        string(STRIP "${_PREV_HASH}" _PREV_HASH)
        if(NOT "${_DEFAULTS_HASH}" STREQUAL "${_PREV_HASH}")
            message(FATAL_ERROR
                "\n"
                "==========================================================\n"
                "  sdkconfig.defaults has changed since your last build.\n"
                "  Your sdkconfig is stale and may be missing critical\n"
                "  settings (optimization, PSRAM, LVGL, power mgmt).\n"
                "\n"
                "  Fix:  rm sdkconfig && idf.py build\n"
                "==========================================================\n"
            )
        endif()
    endif()
    # Stamp current hash — on fresh configure (no sdkconfig) or matching config
    file(WRITE "${_STAMP_FILE}" "${_DEFAULTS_HASH}")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(roon_knob)

# Release configuration gate (#202). Must come after project(): it validates the
# config/sdkconfig.json that IDF resolves during project().
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/rk_release_config.cmake")
