#!/usr/bin/env bash
# CMake-side fixtures for the #202 release-config gate.
#
# tools/test_check_release_config.sh proves the CHECKER's logic. This proves the
# GATE's logic: idf_app/cmake/rk_release_config.cmake is the file that decides
# whether a violating build fails, and its defensive paths (deleted checker, empty
# checker output, tokenless or noise-prefixed checker output, ';' in a message, an
# unwritable report, an interpreter that cannot be launched at all) are reachable
# in exactly the situations where nobody is watching. They were previously covered by construction and by an uncommitted
# scratch harness -- which is the same as not covered.
#
# Dependency-light and portable: bash, cmake, python3. No ESP-IDF, no container,
# no network. Every case builds its own tree under mktemp and cleans up.
#
#   ./tools/test_release_config_cmake.sh
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1   # idf_app/

GATE="$PWD/cmake/rk_release_config.cmake"
HARNESS="$PWD/tools/cmake_gate_harness.cmake"
CHECKER="$PWD/tools/check_release_config.py"
FIX="$PWD/tools/fixtures"
PY="${PYTHON:-python3}"
CMAKE="${CMAKE:-cmake}"

command -v "$CMAKE" >/dev/null 2>&1 || {
    echo "FAIL: '$CMAKE' not found. cmake is required (ESP-IDF needs it too);"
    echo "      set CMAKE=/path/to/cmake to override."
    exit 1
}
for f in "$GATE" "$HARNESS" "$CHECKER"; do
    [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass_count=0
fail_count=0

# tree NAME CONFIG_FIXTURE_OR_EMPTY  -> prints the tree path
tree() {
    local name="$1" cfg="${2:-}"
    local d="$ROOT/$name"
    rm -rf "$d"
    mkdir -p "$d/tools" "$d/config"
    [ -n "$cfg" ] && cp "$FIX/$cfg" "$d/config/sdkconfig.json"
    : > "$d/sdkconfig.defaults"
    printf '%s' "$d"
}

# gate TREE ENFORCE [PYTHON_OVERRIDE] [EXTRA_D...] -> runs the real gate
gate() {
    local d="$1" enforce="$2" py="${3:-$PY}"
    shift 3 2>/dev/null || shift $#
    ( cd "$d" && "$CMAKE" \
        -DGATE="$GATE" \
        -DMARKER="$d/marker.txt" \
        -DRK_TEST_PYTHON="$py" \
        -DRK_ENFORCE_RELEASE_CONFIG="$enforce" \
        "$@" \
        -P "$HARNESS" > "$d/out.txt" 2>&1 )
    return $?
}

# check NAME TREE  EXPECT_FAIL_CALLED(yes|no)  EXPECT_IN_OUTPUT  [EXPECT_IN_LINE0]
check() {
    local name="$1" d="$2" want_fail="$3" want_out="$4" want_line0="${5:-}"
    local ok=1 got_fail="no"
    grep -q '^FAIL_CALLED' "$d/marker.txt" 2>/dev/null && got_fail="yes"

    if [ "$got_fail" != "$want_fail" ]; then
        ok=0; echo "FAIL ${name}: fail_at_build_time called=${got_fail}, expected ${want_fail}"
    fi
    if [ -n "$want_out" ] && ! grep -qF -- "$want_out" "$d/out.txt"; then
        ok=0; echo "FAIL ${name}: gate output does not contain: ${want_out}"
    fi
    if [ -n "$want_line0" ] && ! grep -qF -- "LINE0=${want_line0}" "$d/marker.txt"; then
        ok=0; echo "FAIL ${name}: message_line0 does not contain: ${want_line0}"
    fi
    # Invariants that must hold for every case, not just the interesting ones.
    if grep -q '^EMPTY_LINE0' "$d/marker.txt" 2>/dev/null; then
        ok=0; echo "FAIL ${name}: empty message_line0 (would be a CMake argument error)"
    fi
    if grep -q '^SEMICOLON_LEAK' "$d/marker.txt" 2>/dev/null; then
        ok=0; echo "FAIL ${name}: a ';' reached fail_at_build_time's ARGN"
    fi
    if ! grep -q '^DONE' "$d/marker.txt" 2>/dev/null; then
        ok=0; echo "FAIL ${name}: gate did not run to completion"
    fi

    if [ "$ok" -eq 1 ]; then
        pass_count=$((pass_count + 1))
        printf 'ok   %-44s fail_at_build_time=%s\n' "$name" "$got_fail"
    else
        fail_count=$((fail_count + 1))
        echo "--- gate output (${name}) ---"; sed 's/^/    /' "$d/out.txt"
        echo "--- marker (${name}) ---";      sed 's/^/    /' "$d/marker.txt"
    fi
}

echo "=== gate: compliant config must not fail the build ==="
d="$(tree pass pass.json)"; cp "$CHECKER" "$d/tools/"
gate "$d" ON
check "compliant config, enforcement ON" "$d" no "RK-RELCFG-OK"
# The configure-time gate must never request a log: it has no kconfgen output to
# read, and requesting one would make every local build fail with NOLOG.
if grep -q -- '--log' "$GATE"; then
    fail_count=$((fail_count + 1)); echo "FAIL gate passes --log at configure time"
else
    pass_count=$((pass_count + 1)); printf 'ok   %-44s (no --log requested)\n' "gate does not request a log"
fi
# ...and it must register both configure dependencies, or a defaults edit is missed.
if grep -q 'SET_PROPERTY=.*CMAKE_CONFIGURE_DEPENDS.*check_release_config.py' "$d/marker.txt" \
   && grep -q 'SET_PROPERTY=.*sdkconfig.defaults' "$d/marker.txt"; then
    pass_count=$((pass_count + 1)); printf 'ok   %-44s\n' "registers CONFIGURE_DEPENDS on checker+defaults"
else
    fail_count=$((fail_count + 1)); echo "FAIL CONFIGURE_DEPENDS not registered for both inputs"
fi

echo "=== gate: violation, enforcement ON vs OFF (the load-bearing branch) ==="
d="$(tree viol_on opt_debug.json)"; cp "$CHECKER" "$d/tools/"
gate "$d" ON
check "violation, ON -> fails the build" "$d" yes "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG"
[ -f "$d/config/rk_release_config.json" ] \
  && { pass_count=$((pass_count+1)); printf 'ok   %-44s\n' "ON wrote the report"; } \
  || { fail_count=$((fail_count+1)); echo "FAIL ON did not write a report"; }

d="$(tree viol_off opt_debug.json)"; cp "$CHECKER" "$d/tools/"
gate "$d" OFF
check "violation, OFF -> build continues" "$d" no "RELEASE CONFIG INVARIANTS NOT ENFORCED"
"$PY" - "$d/config/rk_release_config.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["enforced"] is False, r["enforced"]
assert r["verdict"] == "fail", r["verdict"]
PY
if [ $? -eq 0 ]; then
    pass_count=$((pass_count + 1)); printf 'ok   %-44s\n' "OFF still reported enforced:false verdict:fail"
else
    fail_count=$((fail_count + 1)); echo "FAIL OFF report did not record the unenforced failure"
fi

echo "=== gate: defensive paths (each fails CLOSED) ==="
d="$(tree nochecker pass.json)"            # checker deliberately not copied in
gate "$d" ON
check "deleted checker -> NOCHECKER" "$d" yes "RK-RELCFG-NOCHECKER" "RK-RELCFG-NOCHECKER"

d="$(tree emptyout)"; printf 'import sys\nsys.exit(1)\n' > "$d/tools/check_release_config.py"
gate "$d" ON
check "empty checker output -> synthesized line" "$d" yes "" "RK-RELCFG-INTERNAL: checker emitted no RK-RELCFG-* token"

# The two cases above/below are about ATTRIBUTION, and they are separated from the
# empty case deliberately: the gate captures stdout AND stderr of an interpreter it
# does not control, so on a real developer machine the capture is often non-empty
# and still tokenless (an asdf python3 with one broken .pth writes a site-import
# traceback before main() runs). These fixtures pin both halves without depending
# on whether the LOCAL interpreter happens to be noisy -- which is why the empty
# case alone is not sufficient coverage: on a quiet CI interpreter it degenerates
# to the trivially-empty path and proves nothing about noise.
d="$(tree noise_token)"
printf 'print("Error processing line 1 of /x/broken.pth:")\nprint("RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG")\nimport sys\nsys.exit(2)\n' \
    > "$d/tools/check_release_config.py"
gate "$d" ON
check "noise before token -> token heads the failure" "$d" yes "" \
      "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG"
# ...and the demoted line is still passed through rather than dropped. Asserted as
# ">= 2 arguments", not "== 2": this same local interpreter may add ambient stderr
# lines of its own, so an exact count would pass or fail on whose machine it ran.
# Either way, promoting a token must not cost the gate a diagnostic line.
arg_count="$(sed -n 's/^ARG_COUNT=//p' "$d/marker.txt")"
if [ "${arg_count:-0}" -ge 2 ]; then
    pass_count=$((pass_count + 1)); printf 'ok   %-44s args=%s\n' "demoted noise preserved below line0" "$arg_count"
else
    fail_count=$((fail_count + 1)); echo "FAIL noise line was dropped instead of demoted (ARG_COUNT=${arg_count:-unset})"
    sed 's/^/    /' "$d/marker.txt"
fi

d="$(tree noise_only)"
printf 'import sys\nsys.stderr.write("Error processing line 1 of /x/broken.pth:\\n")\nsys.exit(1)\n' \
    > "$d/tools/check_release_config.py"
gate "$d" ON
check "tokenless noise -> synthesized, noise not line0" "$d" yes "" \
      "RK-RELCFG-INTERNAL: checker emitted no RK-RELCFG-* token (result=1)"
if grep -q '^LINE0=Error processing' "$d/marker.txt"; then
    fail_count=$((fail_count + 1)); echo "FAIL interpreter noise became message_line0"
else
    pass_count=$((pass_count + 1)); printf 'ok   %-44s\n' "interpreter noise never becomes line0"
fi

d="$(tree semis)"
printf 'print("RK-RELCFG-VIOLATION: A;B;C")\nprint("")\nprint("second; line")\nimport sys\nsys.exit(2)\n' \
    > "$d/tools/check_release_config.py"
gate "$d" ON
check "';' in output sanitized to ','" "$d" yes "" "RK-RELCFG-VIOLATION: A,B,C"

d="$(tree noreport pass.json)"; cp "$CHECKER" "$d/tools/"
rm -rf "$d/config/rk_release_config.json"; mkdir -p "$d/config/rk_release_config.json"
gate "$d" ON
check "unwritable report -> NOREPORT" "$d" yes "RK-RELCFG-NOREPORT"

# execute_process() sets RESULT_VARIABLE to an error STRING when the command
# cannot be launched. `if(NOT result STREQUAL "0")` handles that; `EQUAL` would
# not, and the gate would pass on a broken interpreter.
d="$(tree nonnumeric pass.json)"; cp "$CHECKER" "$d/tools/"
gate "$d" ON "$ROOT/definitely-not-an-interpreter"
check "unlaunchable interpreter -> fails closed" "$d" yes ""

echo "=== gate: required ESP-IDF commands are checked up front ==="
# Without the guard, a missing fail_at_build_time() surfaces as CMake's unlabelled
# "Unknown CMake command" at the exact moment the gate is trying to block a
# violating build. Must be attributable instead. Configure-time failure is
# intended here: a missing helper is an environment defect, not a config verdict.
d="$(tree nohelper opt_debug.json)"; cp "$CHECKER" "$d/tools/"
gate "$d" ON "$PY" -DRK_TEST_OMIT_FAIL_HELPER=1
rc=$?
ok=1
[ "$rc" -eq 0 ] && { ok=0; echo "FAIL missing fail_at_build_time: gate exited 0, expected a configure failure"; }
grep -qF 'RK-RELCFG-NOHELPER' "$d/out.txt" || { ok=0; echo "FAIL missing fail_at_build_time: no RK-RELCFG-NOHELPER token"; }
# Match on the quoted command name only: CMake hard-wraps message() text, so any
# longer phrase can straddle a line break.
grep -qF "'fail_at_build_time'" "$d/out.txt" || { ok=0; echo "FAIL missing fail_at_build_time: message does not name the command"; }
grep -qF 'Unknown CMake command' "$d/out.txt" && { ok=0; echo "FAIL missing fail_at_build_time: reached the unlabelled CMake error"; }
if [ "$ok" -eq 1 ]; then
    pass_count=$((pass_count + 1))
    printf 'ok   %-44s exit=%s attributable\n' "missing fail_at_build_time" "$rc"
else
    fail_count=$((fail_count + 1)); echo "--- gate output ---"; sed 's/^/    /' "$d/out.txt"
fi

echo
echo "=== ${pass_count} passed, ${fail_count} failed ==="
[ "$fail_count" -eq 0 ] || exit 1
echo "RK-RELCFG-CMAKE-FIXTURES-OK"
