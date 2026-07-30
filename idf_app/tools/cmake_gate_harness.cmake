# Host-only harness for idf_app/cmake/rk_release_config.cmake. Issue #202.
#
# Runs the REAL gate logic under `cmake -P`, with the two ESP-IDF commands it
# depends on stubbed, so the decision paths that decide whether a build fails can
# be tested without ESP-IDF, without a container, and in milliseconds:
#
#   * fail_at_build_time() is called only when it should be
#   * its first argument (message_line0, a REQUIRED positional) is never empty --
#     an empty capture would be a configure-time CMake argument error, i.e. the
#     hard failure that wedges menuconfig, which is the mode the design avoids
#   * no argument contains ';' -- the helper does foreach(line ${ARGN}), which
#     splits on it
#
# In `cmake -P` script mode CMAKE_BINARY_DIR and CMAKE_CURRENT_SOURCE_DIR are both
# the working directory, so a fake tree places the checker at tools/ and the
# resolved config at config/ relative to the cwd. Results are written to MARKER
# because script-mode cache writes are not visible back in the including scope.
#
# Driven by tools/test_release_config_cmake.sh; not used by any build.
#
# Required -D arguments:
#   GATE           path to cmake/rk_release_config.cmake
#   MARKER         path to write results to
#   RK_TEST_PYTHON interpreter handed back by the stubbed idf_build_get_property
#   RK_ENFORCE_RELEASE_CONFIG  ON or OFF, as a real build would pass it

function(idf_build_get_property outvar prop)
    if(prop STREQUAL "PYTHON")
        set(${outvar} "${RK_TEST_PYTHON}" PARENT_SCOPE)
    else()
        set(${outvar} "" PARENT_SCOPE)
    endif()
endfunction()

# RK_TEST_OMIT_FAIL_HELPER=1 leaves fail_at_build_time UNDEFINED, so the gate's
# required-command guard can be tested: the gate must refuse attributably rather
# than reaching CMake's unlabelled "Unknown CMake command".
if(NOT RK_TEST_OMIT_FAIL_HELPER)

function(fail_at_build_time target_name message_line0)
    if(message_line0 STREQUAL "")
        file(APPEND "${MARKER}" "EMPTY_LINE0\n")
        message(FATAL_ERROR "HARNESS: message_line0 was EMPTY -> CMake argument error")
    endif()
    file(APPEND "${MARKER}" "FAIL_CALLED target=${target_name}\n")
    file(APPEND "${MARKER}" "LINE0=${message_line0}\n")
    foreach(arg "${message_line0}" ${ARGN})
        if(arg MATCHES ";")
            file(APPEND "${MARKER}" "SEMICOLON_LEAK=${arg}\n")
            message(FATAL_ERROR "HARNESS: argument contains ';': ${arg}")
        endif()
    endforeach()
    list(LENGTH ARGN extra)
    math(EXPR total "${extra} + 1")
    file(APPEND "${MARKER}" "ARG_COUNT=${total}\n")
endfunction()

endif()  # NOT RK_TEST_OMIT_FAIL_HELPER

# Script mode has no directory scope; stub it and record what was registered.
function(set_property)
    file(APPEND "${MARKER}" "SET_PROPERTY=${ARGN}\n")
endfunction()

file(WRITE "${MARKER}" "")
include("${GATE}")
file(APPEND "${MARKER}" "DONE\n")
