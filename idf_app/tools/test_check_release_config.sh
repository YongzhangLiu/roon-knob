#!/usr/bin/env bash
# Fixture runner for the #202 release-config gate.
#
# Proves the checker's LOGIC, on the host, in seconds, with no ESP-IDF and no
# container: python3 only. Every case asserts the EXACT exit code and the EXACT
# RK-RELCFG token, because "the build failed" and "the gate fired for this
# reason" are the two things #202 exists to stop conflating.
#
# It also carries the assert-the-assertion cases (folded in here rather than
# living as a separate CI job): tools/assert_release_report.py is the layer that
# makes CI's enforcement non-optional, so it must itself be proven to reject a
# report that says "not enforced", a report whose digest belongs to another
# build, and a missing report.
#
#   ./tools/test_check_release_config.sh
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1   # idf_app/

CHECKER="tools/check_release_config.py"
ASSERTER="tools/assert_release_report.py"
FIX="tools/fixtures"
PY="${PYTHON:-python3}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass_count=0
fail_count=0

# expect NAME EXPECTED_EXIT EXPECTED_SUBSTRING -- COMMAND...
expect() {
    local name="$1" want_rc="$2" want_txt="$3"
    shift 3
    [ "${1:-}" = "--" ] && shift

    local out rc
    out="$("$@" 2>&1)"
    rc=$?

    local ok=1
    if [ "$rc" -ne "$want_rc" ]; then
        ok=0
        echo "FAIL ${name}: exit ${rc}, expected ${want_rc}"
    fi
    if [ -n "$want_txt" ] && ! printf '%s' "$out" | grep -qF -- "$want_txt"; then
        ok=0
        echo "FAIL ${name}: output does not contain: ${want_txt}"
    fi
    if [ "$ok" -eq 1 ]; then
        pass_count=$((pass_count + 1))
        printf 'ok   %-46s exit=%s token=%s\n' "$name" "$rc" "$want_txt"
    else
        fail_count=$((fail_count + 1))
        echo "--- output of ${name} ---"
        printf '%s\n' "$out"
        echo "--- end ---"
    fi
}

# refute NAME FORBIDDEN_SUBSTRING -- COMMAND...   (command may exit non-zero)
refute() {
    local name="$1" forbidden="$2"
    shift 2
    [ "${1:-}" = "--" ] && shift
    local out
    out="$("$@" 2>&1)"
    if printf '%s' "$out" | grep -qF -- "$forbidden"; then
        fail_count=$((fail_count + 1))
        echo "FAIL ${name}: output leaked forbidden text: ${forbidden}"
    else
        pass_count=$((pass_count + 1))
        printf 'ok   %-46s (absent: %s)\n' "$name" "$forbidden"
    fi
}

echo "=== checker: positive cases ==="
expect "pass (SIZE selected)"          0 "RK-RELCFG-OK"                     -- "$PY" "$CHECKER" --config "$FIX/pass.json"
expect "pass (PERF selected)"          0 "RK-RELCFG-OK"                     -- "$PY" "$CHECKER" --config "$FIX/pass_perf.json"
expect "absent false-symbol satisfies" 0 "RK-RELCFG-OK"                     -- "$PY" "$CHECKER" --config "$FIX/absent_debug_stubs.json"

echo "=== checker: optimization invariant ==="
expect "DEBUG rejected"                2 "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG"  -- "$PY" "$CHECKER" --config "$FIX/opt_debug.json"
expect "NONE rejected"                 2 "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_NONE"   -- "$PY" "$CHECKER" --config "$FIX/opt_none.json"
expect "SIZE+PERF both on rejected"    2 "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_CHOICE" -- "$PY" "$CHECKER" --config "$FIX/opt_both.json"
expect "whole choice absent != pass"   4 "RK-RELCFG-UNDEFINED: COMPILER_OPTIMIZATION"        -- "$PY" "$CHECKER" --config "$FIX/opt_missing.json"

echo "=== checker: platform and debug-behaviour invariants ==="
expect "SPIRAM false rejected"         2 "RK-RELCFG-VIOLATION: SPIRAM"                                    -- "$PY" "$CHECKER" --config "$FIX/no_spiram.json"
expect "SPIRAM absent rejected"        2 "RK-RELCFG-VIOLATION: SPIRAM"                                    -- "$PY" "$CHECKER" --config "$FIX/absent_spiram.json"
expect "flash size mismatch rejected"  2 "RK-RELCFG-VIOLATION: ESPTOOLPY_FLASHSIZE"                       -- "$PY" "$CHECKER" --config "$FIX/wrong_flashsize.json"
expect "panic gdbstub rejected"        2 "RK-RELCFG-VIOLATION: ESP_SYSTEM_PANIC_GDBSTUB"                  -- "$PY" "$CHECKER" --config "$FIX/panic_gdbstub.json"
expect "assertions off rejected"       2 "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE"   -- "$PY" "$CHECKER" --config "$FIX/assertions_off.json"

echo "=== checker: identifies its own failure ==="
expect "malformed json"                3 "RK-RELCFG-NOCONFIG"  -- "$PY" "$CHECKER" --config "$FIX/malformed.json"
expect "json is not an object"         3 "RK-RELCFG-NOCONFIG"  -- "$PY" "$CHECKER" --config "$FIX/not_an_object.json"
expect "config file absent"            3 "RK-RELCFG-NOCONFIG"  -- "$PY" "$CHECKER" --config "$FIX/does_not_exist.json"
expect "usage error is not a verdict"  64 "RK-RELCFG-USAGE"    -- "$PY" "$CHECKER"

echo "=== checker: undefined defaults are kconfgen's verdict ==="
expect "kconfgen unknown symbol -> 4"  4 "RK-RELCFG-UNDEFINED: CONFIG_WIFI_SSID" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_undefined.log"
expect "kconfgen unknown, 2nd symbol"  4 "RK-RELCFG-UNDEFINED: CONFIG_LWIP_NETIF_HOSTNAME" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_undefined.log"
refute "assigned value never echoed"     "fixture-value-must-never-be-echoed" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_undefined.log"
expect "rename aliases are not flagged" 0 "RK-RELCFG-OK" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_rename.log"

echo "=== checker: a REQUESTED log that cannot be read is a failure, not silence ==="
# Regression: this exact invocation used to exit 0 with RK-RELCFG-OK, which made the
# kconfgen-delegated undefined-symbol gate fail OPEN whenever the log went missing.
expect "missing requested log -> NOLOG"  5 "RK-RELCFG-NOLOG: requested log could not be read" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$TMP/never_written.log"
expect "empty requested log -> NOLOG"    5 "RK-RELCFG-NOLOG: requested log is empty" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/empty.log"
expect "whitespace-only log -> NOLOG"    5 "RK-RELCFG-NOLOG: requested log is empty" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/whitespace_only.log"
expect "required marker absent -> NOLOG"  5 "RK-RELCFG-NOLOG: no requested log contains the required marker" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_rename.log" \
       --log-must-contain "RK-RELCFG-VERDICT:"
expect "required marker present -> OK"   0 "RK-RELCFG-OK" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_rename.log" \
       --log-must-contain "Configuring done"
# The configure-time CMake gate passes no --log at all: not requested, must not fail.
expect "no --log requested -> not a failure" 0 "RK-RELCFG-OK" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json"
refute "NOLOG path never echoes values"  "fixture-value-must-never-be-echoed" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_undefined.log" \
       --log-must-contain "RK-RELCFG-VERDICT:"

echo "=== checker: a REQUESTED report that cannot be written is a failure ==="
# Destinations chosen to fail for STRUCTURAL reasons, not permission reasons, so
# these cases are deterministic on every platform and are not skipped when the
# suite runs as root (where chmod 555 would be ignored):
#   * parent component is an existing FILE -> makedirs raises
#   * destination is an existing DIRECTORY -> open() raises
expect "report parent is a file -> NOREPORT" 6 "RK-RELCFG-NOREPORT: requested report could not be written" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --report "$FIX/pass.json/report.json"
expect "report dest is a directory -> NOREPORT" 6 "RK-RELCFG-NOREPORT: requested report could not be written" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --report "$TMP"
expect "no OK token after a failed write" 6 "RK-RELCFG-VERDICT: fail" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --report "$FIX/pass.json/report.json" --enforced yes
refute "OK is withdrawn, not merely joined" "RK-RELCFG-OK" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --report "$FIX/pass.json/report.json" --enforced yes
expect "no --report requested -> not a failure" 0 "RK-RELCFG-OK" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --enforced yes
# A partial report must never be left where a reader would parse it as a pass.
expect "atomic write leaves no .tmp residue" 0 "no-tmp-residue" -- "$PY" -c "
import os, subprocess, sys
dest = '$TMP/atomic.json'
subprocess.run([sys.executable, '$CHECKER', '--config', '$FIX/pass.json',
                '--report', dest], capture_output=True, cwd='$PWD')
assert os.path.exists(dest), 'report missing'
assert not os.path.exists(dest + '.tmp'), 'temp file left behind'
print('no-tmp-residue')
"

echo "=== checker: ;-to-, sanitation for fail_at_build_time's ARGN split ==="
# CMake's fail_at_build_time() does foreach(line \${ARGN}), which splits on ';'.
# Drive a ';' through the real emit path via a reported path and a marker, and
# require it to come out as ',' -- asserted here, not only reasoned about.
expect "semicolon in emitted path becomes comma" 0 "semi,colon.json" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --report "$TMP/semi;colon.json"
refute "no raw semicolon survives to output"  "semi;colon.json" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --report "$TMP/semi;colon2.json"
expect "semicolon in NOLOG reason becomes comma" 5 "marker 'a,b'" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_rename.log" \
       --log-must-contain "a;b"

echo "=== checker: token precedence NOCONFIG > NOREPORT > NOLOG > UNDEFINED > VIOLATION ==="
expect "NOCONFIG outranks NOREPORT"  3 "RK-RELCFG-NOCONFIG" \
    -- "$PY" "$CHECKER" --config "$FIX/malformed.json" --report "$FIX/pass.json/report.json"
expect "NOREPORT outranks NOLOG"     6 "RK-RELCFG-NOREPORT" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$TMP/never_written.log" \
       --report "$FIX/pass.json/report.json"
expect "NOREPORT outranks UNDEFINED" 6 "RK-RELCFG-UNDEFINED: CONFIG_WIFI_SSID" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_undefined.log" \
       --report "$FIX/pass.json/report.json"
expect "NOREPORT outranks VIOLATION"  6 "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG" \
    -- "$PY" "$CHECKER" --config "$FIX/opt_debug.json" --report "$FIX/pass.json/report.json"
expect "NOCONFIG outranks NOLOG"    3 "RK-RELCFG-NOCONFIG" \
    -- "$PY" "$CHECKER" --config "$FIX/malformed.json" --log "$TMP/never_written.log"
expect "NOLOG outranks UNDEFINED"   5 "RK-RELCFG-NOLOG" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_undefined.log" \
       --log "$TMP/never_written.log"
expect "UNDEFINED outranks VIOLATION" 4 "RK-RELCFG-UNDEFINED: CONFIG_WIFI_SSID" \
    -- "$PY" "$CHECKER" --config "$FIX/opt_debug.json" --log "$FIX/kconfgen_undefined.log"
expect "outranked tokens stay visible"  4 "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG" \
    -- "$PY" "$CHECKER" --config "$FIX/opt_debug.json" --log "$FIX/kconfgen_undefined.log"

echo "=== checker: report and banner ==="
expect "report written, enforced=yes"  0 "RK-RELCFG-ENFORCED" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --enforced yes --report "$TMP/enforced.json"
expect "not-enforced banner is loud"   0 "*** RELEASE CONFIG INVARIANTS NOT ENFORCED" \
    -- "$PY" "$CHECKER" --config "$FIX/pass.json" --enforced no --report "$TMP/unenforced.json"
expect "OFF still writes a report"     2 "RK-RELCFG-REPORT" \
    -- "$PY" "$CHECKER" --config "$FIX/opt_debug.json" --enforced no --report "$TMP/off_fail.json"
expect "enforcement never alters exit" 2 "RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG" \
    -- "$PY" "$CHECKER" --config "$FIX/opt_debug.json" --enforced no

expect "report records enforced/verdict/digest" 0 "report-fields-ok" -- "$PY" -c "
import json,sys,hashlib
r=json.load(open('$TMP/enforced.json'))
d='sha256:'+hashlib.sha256(open('$FIX/pass.json','rb').read()).hexdigest()
assert r['schema']=='rk-release-config/1', r['schema']
assert r['enforced'] is True, r['enforced']
assert r['verdict']=='pass', r['verdict']
assert r['config_digest']==d, r['config_digest']
assert len(r['invariants'])==11, len(r['invariants'])   # 1 choice + 9 bool + 1 string
u=json.load(open('$TMP/unenforced.json'))
assert u['enforced'] is False and u['verdict']=='pass'
f=json.load(open('$TMP/off_fail.json'))
assert f['enforced'] is False and f['verdict']=='fail', f['verdict']
print('report-fields-ok')
"
expect "no invariant row is silently absent" 0 "rows-complete" -- "$PY" -c "
import json
r=json.load(open('$TMP/enforced.json'))
names={row['name'] for row in r['invariants']}
need={'COMPILER_OPTIMIZATION','COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE','SPIRAM',
      'PARTITION_TABLE_CUSTOM','HEAP_POISONING_DISABLED','HEAP_TRACING_OFF',
      'COMPILER_DUMP_RTL_FILES','ESP_DEBUG_STUBS_ENABLE','ESP_SYSTEM_PANIC_GDBSTUB',
      'FREERTOS_USE_TRACE_FACILITY','ESPTOOLPY_FLASHSIZE'}
missing=need-names
assert not missing, missing
assert all('actual' in row and 'status' in row for row in r['invariants'])
print('rows-complete')
"

echo "=== checker: the report proves which logs were read ==="
"$PY" "$CHECKER" --config "$FIX/pass.json" --log "$FIX/kconfgen_rename.log" \
    --log-must-contain "Configuring done" --enforced yes --report "$TMP/withlog.json" >/dev/null 2>&1
expect "report records log evidence" 0 "log-evidence-ok" -- "$PY" -c "
import json
r=json.load(open('$TMP/withlog.json'))
assert r['logs_requested']==1, r['logs_requested']
e=r['logs_scanned'][0]
assert e['read'] is True and e['bytes']>0, e
assert 'Configuring done' in e['markers_found'], e
assert r['log_problems']==[], r['log_problems']
assert r['logs_required_markers']==['Configuring done'], r['logs_required_markers']
print('log-evidence-ok')
"

echo "=== assert-the-assertion: the host gate must have teeth ==="
expect "good report accepted"          0 "RK-RELCFG-ASSERT-OK" \
    -- "$PY" "$ASSERTER" --report "$TMP/enforced.json" --config "$FIX/pass.json"
expect "enforced:false REJECTED"       1 "RK-RELCFG-ASSERT-FAIL" \
    -- "$PY" "$ASSERTER" --report "$FIX/report_enforced_false.json"
expect "digest mismatch REJECTED"      1 "does not describe this build" \
    -- "$PY" "$ASSERTER" --report "$TMP/enforced.json" --config "$FIX/pass_perf.json"
expect "missing report REJECTED"       1 "RK-RELCFG-ASSERT-FAIL" \
    -- "$PY" "$ASSERTER" --report "$TMP/no_such_report.json"
expect "failing verdict REJECTED"      1 "RK-RELCFG-ASSERT-FAIL" \
    -- "$PY" "$ASSERTER" --report "$TMP/off_fail.json"
expect "logs-read proof accepted"      0 "RK-RELCFG-ASSERT-OK" \
    -- "$PY" "$ASSERTER" --report "$TMP/withlog.json" --config "$FIX/pass.json" --require-logs-read
expect "unread log REJECTED"           1 "report says log was not read" \
    -- "$PY" "$ASSERTER" --report "$FIX/report_logs_unread.json" --require-logs-read
expect "no log scanned REJECTED"       1 "report proves no log was read" \
    -- "$PY" "$ASSERTER" --report "$TMP/enforced.json" --config "$FIX/pass.json" --require-logs-read

echo "=== assert-the-assertion: log identity must be CALLER-owned ==="
# The report cannot be its own witness that a marker was required: if a workflow
# edit drops --log-must-contain, logs_required_markers is [] and any check driven
# from it iterates zero times. These three cases pin that gap shut.
expect "empty marker metadata still ACCEPTED by --require-logs-read" 0 "RK-RELCFG-ASSERT-OK" \
    -- "$PY" "$ASSERTER" --report "$FIX/report_logs_no_required_markers.json" --require-logs-read
expect "...but REJECTED by --expect-log-marker" 1 "does not show expected log marker" \
    -- "$PY" "$ASSERTER" --report "$FIX/report_logs_no_required_markers.json" \
       --require-logs-read --expect-log-marker "RK-RELCFG-VERDICT:"
expect "self-consistent WRONG log REJECTED" 1 "not the one the gate wrote" \
    -- "$PY" "$ASSERTER" --report "$FIX/report_logs_wrong_marker.json" \
       --require-logs-read --expect-log-marker "RK-RELCFG-VERDICT:"
expect "expected marker with no scanned log REJECTED" 1 "scanned no log" \
    -- "$PY" "$ASSERTER" --report "$TMP/enforced.json" --expect-log-marker "RK-RELCFG-VERDICT:"
expect "real gate report satisfies the caller marker" 0 "RK-RELCFG-ASSERT-OK" \
    -- "$PY" "$ASSERTER" --report "$TMP/withlog.json" --config "$FIX/pass.json" \
       --require-logs-read --expect-log-marker "Configuring done"

# The stale-config integration negative asserts its report this way.
"$PY" "$CHECKER" --config "$FIX/opt_debug.json" --enforced yes --report "$TMP/stale.json" >/dev/null 2>&1
expect "stale-config report is verdict:fail" 0 "RK-RELCFG-ASSERT-OK" \
    -- "$PY" "$ASSERTER" --report "$TMP/stale.json" --config "$FIX/opt_debug.json" \
       --expect-verdict fail --expect-enforced true

echo
echo "=== ${pass_count} passed, ${fail_count} failed ==="
[ "$fail_count" -eq 0 ] || exit 1
echo "RK-RELCFG-FIXTURES-OK"
