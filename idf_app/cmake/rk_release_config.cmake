# Effective release-configuration gate. Issue #202.
#
# Included from CMakeLists.txt *after* project(), because that is when IDF has
# finished resolving the configuration and has written
# ${CMAKE_BINARY_DIR}/config/sdkconfig.json. That generated file -- not
# sdkconfig.defaults -- is the only thing the checker reads: committed defaults
# are an input that can be stale, renamed, ignored because sdkconfig already
# exists, or overridden by sdkconfig.local / SDKCONFIG_DEFAULTS / -D, so they
# cannot prove what the compiler actually used.
#
# Behaviour:
#   * The checker ALWAYS runs and ALWAYS writes its report, enforced or not.
#   * RK_ENFORCE_RELEASE_CONFIG=OFF suppresses the build FAILURE only. It never
#     suppresses the report or the banner, so an unenforced build is loud in the
#     log and self-describing in config/rk_release_config.json.
#   * Failure is deferred via fail_at_build_time() rather than FATAL_ERROR, so
#     `idf.py menuconfig` and `idf.py reconfigure` still work from a violating
#     tree. Both documented recovery paths (fix it in menuconfig, or
#     `rm sdkconfig && idf.py build`) stay reachable WITHOUT the escape hatch,
#     which is what keeps the opt-out from becoming the path of least resistance.
#
# Enforcement ceilings, stated here as well as in the ADR because the comment is
# what the next maintainer reads:
#   * fail_at_build_time() creates an ALL target, so the gate fires for
#     `idf.py build` but not for target-selected invocations such as `idf.py app`.
#     Local coverage is therefore ergonomic, not absolute.
#   * Real non-optionality lives in CI: the workflow forces enforcement ON and
#     then asserts this report on the host (tools/assert_release_report.py).
#     Deleting that host step is not detectable from inside the repo; closing
#     that hole needs branch protection with required checks, which #202 does
#     not touch.

if(NOT COMMAND idf_build_get_property)
    message(FATAL_ERROR
        "rk_release_config.cmake must be included after project(); it needs IDF's "
        "build properties and its resolved config/sdkconfig.json.")
endif()

option(RK_ENFORCE_RELEASE_CONFIG
       "Fail the build when the resolved configuration violates #202 release invariants" ON)

set(RK_RELCFG_CHECKER  "${CMAKE_CURRENT_SOURCE_DIR}/tools/check_release_config.py")
set(RK_RELCFG_DEFAULTS "${CMAKE_CURRENT_SOURCE_DIR}/sdkconfig.defaults")
set(RK_RELCFG_CONFIG   "${CMAKE_BINARY_DIR}/config/sdkconfig.json")
set(RK_RELCFG_REPORT   "${CMAKE_BINARY_DIR}/config/rk_release_config.json")

# Re-run configure when the checker or the committed defaults change. IDF
# registers sdkconfig, sdkconfig.h and sdkconfig.cmake as configure dependencies
# but NOT sdkconfig.defaults, so without this line a defaults edit would not
# re-evaluate the gate. (This is also #149's one non-substitutable contribution;
# see the staleness guard in CMakeLists.txt.)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
             "${RK_RELCFG_CHECKER}" "${RK_RELCFG_DEFAULTS}")

idf_build_get_property(rk_relcfg_python PYTHON)
if(NOT rk_relcfg_python)
    set(rk_relcfg_python "python3")
endif()

if(RK_ENFORCE_RELEASE_CONFIG)
    set(rk_relcfg_enforced "yes")
else()
    set(rk_relcfg_enforced "no")
endif()

if(NOT EXISTS "${RK_RELCFG_CHECKER}")
    # Fail closed: a deleted checker must not read as a clean build.
    set(rk_relcfg_text "RK-RELCFG-NOCHECKER: ${RK_RELCFG_CHECKER} is missing")
    set(rk_relcfg_result "1")
else()
    execute_process(
        COMMAND "${rk_relcfg_python}" "${RK_RELCFG_CHECKER}"
                --config   "${RK_RELCFG_CONFIG}"
                --report   "${RK_RELCFG_REPORT}"
                --defaults "${RK_RELCFG_DEFAULTS}"
                --enforced "${rk_relcfg_enforced}"
        OUTPUT_VARIABLE rk_relcfg_stdout
        ERROR_VARIABLE  rk_relcfg_stderr
        RESULT_VARIABLE rk_relcfg_result)
    set(rk_relcfg_text "${rk_relcfg_stdout}${rk_relcfg_stderr}")
endif()

# Always emit the banner and the checker's own lines, enforced or not.
message(STATUS
        "RK release config gate (#202): enforcement=${rk_relcfg_enforced} "
        "result=${rk_relcfg_result} report=${RK_RELCFG_REPORT}")
message(STATUS "${rk_relcfg_text}")

# Prepare fail_at_build_time() arguments. Two hardening requirements, both real:
#   * message_line0 is a REQUIRED positional, so an empty capture would become a
#     configure-time CMake argument error -- the hard failure that wedges
#     menuconfig, i.e. exactly the mode this design avoids. Guarantee non-empty.
#   * the helper does foreach(line ${ARGN}), which splits on ';'. The checker
#     already strips ';' from its output; this is the second line of defence.
string(REPLACE ";" "," rk_relcfg_safe "${rk_relcfg_text}")
string(REGEX REPLACE "\r?\n" ";" rk_relcfg_lines "${rk_relcfg_safe}")
list(FILTER rk_relcfg_lines EXCLUDE REGEX "^[ \t]*$")
list(LENGTH rk_relcfg_lines rk_relcfg_line_count)
if(rk_relcfg_line_count EQUAL 0)
    set(rk_relcfg_lines
        "RK-RELCFG-INTERNAL: checker produced no output (result=${rk_relcfg_result})")
endif()

# STREQUAL, not EQUAL: execute_process() sets RESULT_VARIABLE to an error STRING
# when the command cannot be launched at all, and EQUAL on a non-numeric value is
# not a comparison this gate should rely on.
if(NOT rk_relcfg_result STREQUAL "0")
    if(RK_ENFORCE_RELEASE_CONFIG)
        fail_at_build_time(rk_release_config ${rk_relcfg_lines})
    else()
        message(WARNING
                "Release config invariants FAILED but RK_ENFORCE_RELEASE_CONFIG=OFF, so the "
                "build will continue. This artifact is not release-eligible. See "
                "${RK_RELCFG_REPORT}")
    endif()
endif()
