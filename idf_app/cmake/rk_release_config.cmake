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
#   * fail_at_build_time() creates an ALL target, so the gate fires for anything
#     that builds `all` -- which includes `idf.py build` AND `idf.py flash`
#     (its action carries dependencies/order_dependencies on `all`). The bypass
#     is narrower than "target-selected invocations": specifically `idf.py app`
#     and `idf.py app-flash`, which build the app target directly. Local coverage
#     is therefore broad but not absolute.
#   * CI's non-optionality is real but narrow. The workflow forces enforcement ON
#     and then asserts this report on the host (tools/assert_release_report.py),
#     so a build-idf job cannot run unenforced; and publication is gated via
#     needs:. Be exact about WHICH publication, because the two consumers gate on
#     DIFFERENT sets: `release` needs ALL THREE proof jobs -- needs: [build-idf,
#     release-config-fixtures, build-stale-config] -- whereas deploy-pr-preview
#     needs ONLY TWO -- needs: [build-idf, release-config-fixtures] -- and does
#     NOT need build-stale-config. So a red build-stale-config ALONE stops a
#     release but does NOT stop a flashable PR preview, which can still publish
#     from a tree whose stale-config integration proof is failing. Two further
#     things none of this covers: deleting the host step is not detectable from
#     inside the repo, and CI does not gate MERGING -- branch protection on
#     master currently defines NO required status checks, so nothing here stops
#     a merge with these jobs red. Closing either needs required checks, which
#     are absent today and which #202 does not touch.
#   * RK_ENFORCE_RELEASE_CONFIG is a CMake CACHE variable: once set to OFF in a
#     build tree it persists for every later build in that tree. The banner is
#     re-emitted on every configure so the state stays visible rather than
#     silently inherited.

# Both ESP-IDF commands this gate depends on are checked up front. Without this,
# a missing fail_at_build_time() surfaces only later, as CMake's unlabelled
# "Unknown CMake command", at the exact moment the gate is trying to block a
# violating build -- an attribution failure in the one path that must be legible.
# A missing helper is an environment defect (IDF's utilities.cmake no longer
# provides a documented helper), not a configuration violation, so failing loudly
# at configure time is correct here even though the gate itself deliberately
# defers. When both commands exist, behaviour and recovery are unchanged.
foreach(_rk_required_command idf_build_get_property fail_at_build_time)
    if(NOT COMMAND ${_rk_required_command})
        message(FATAL_ERROR
            "RK-RELCFG-NOHELPER: required ESP-IDF CMake command "
            "'${_rk_required_command}' is not defined.\n"
            "  * If this fired from idf_app/CMakeLists.txt, the include() of "
            "cmake/rk_release_config.cmake must come AFTER project(): the gate "
            "needs IDF's build properties and its resolved config/sdkconfig.json.\n"
            "  * If the include is already after project(), this ESP-IDF version no "
            "longer provides '${_rk_required_command}' "
            "(tools/cmake/utilities.cmake). The release config gate cannot fail "
            "closed without it, so it refuses to run rather than pass silently. "
            "See docs/meta/decisions/2026-07-29_DECISION_EFFECTIVE_RELEASE_CONFIG.md")
    endif()
endforeach()

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

# Prepare fail_at_build_time() arguments. Three hardening requirements, all real:
#   * message_line0 is a REQUIRED positional, so an empty capture would become a
#     configure-time CMake argument error -- the hard failure that wedges
#     menuconfig, i.e. exactly the mode this design avoids. Guarantee non-empty.
#   * the helper does foreach(line ${ARGN}), which splits on ';'. The checker
#     already strips ';' from its output; this is the second line of defence.
#   * message_line0 must be ATTRIBUTABLE to this gate. The capture is stdout AND
#     stderr of an interpreter this gate does not control, and real ones are noisy:
#     an asdf-managed python3 with one broken .pth file writes a site-import
#     traceback to stderr before the checker's main() ever runs. Taking the first
#     captured line verbatim then heads the build failure with "Error processing
#     line 1 of .../matplotlib-nspkg.pth" -- an unattributable message from the one
#     component whose whole job is to say why the build stopped.
string(REPLACE ";" "," rk_relcfg_safe "${rk_relcfg_text}")
string(REGEX REPLACE "\r?\n" ";" rk_relcfg_lines "${rk_relcfg_safe}")
list(FILTER rk_relcfg_lines EXCLUDE REGEX "^[ \t]*$")

# Line 0 is the checker's FIRST RK-RELCFG-* token when it emitted one, otherwise a
# synthesized RK-RELCFG-INTERNAL line. Ambient noise is never discarded -- only
# demoted below that header -- so nothing diagnostic is lost, and a token found
# further down the capture (interpreter noise on stdout, verdict on stderr) still
# gets to name the failure. Anchored, so a noise line that merely MENTIONS a token
# further along cannot claim line 0.
set(rk_relcfg_line0 "")
set(rk_relcfg_line0_index 0)
foreach(rk_relcfg_line IN LISTS rk_relcfg_lines)
    if(rk_relcfg_line MATCHES "^[ \t]*RK-RELCFG-")
        set(rk_relcfg_line0 "${rk_relcfg_line}")
        break()
    endif()
    math(EXPR rk_relcfg_line0_index "${rk_relcfg_line0_index} + 1")
endforeach()

if(rk_relcfg_line0 STREQUAL "")
    # No token anywhere: an empty capture, or ambient interpreter output only. The
    # synthesized line carries the exit status -- safe, and already printed in the
    # banner above -- and nothing from the capture itself, which is precisely the
    # content that could not be attributed. RESULT_VARIABLE can be an error STRING
    # rather than a number, so it gets the same ';' treatment as the capture.
    string(REPLACE ";" "," rk_relcfg_safe_result "${rk_relcfg_result}")
    set(rk_relcfg_line0 "RK-RELCFG-INTERNAL: checker emitted no RK-RELCFG-* token (result=${rk_relcfg_safe_result})")
else()
    list(REMOVE_AT rk_relcfg_lines ${rk_relcfg_line0_index})
endif()
set(rk_relcfg_lines "${rk_relcfg_line0}" ${rk_relcfg_lines})

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
