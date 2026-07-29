#!/usr/bin/env bash
# Measure DEBUG / SIZE / PERF optimization modes for issue #202.
#
# TEMPORARY MEASUREMENT HARNESS. This exists only to produce the evidence for
# #202's first acceptance criterion ("Measure current master with DEBUG, SIZE,
# and PERF ... and select the release mode with a documented rationale"). It is
# not part of the release build and is expected to be removed once the decision
# record carries the numbers.
#
# Run this INSIDE the same container image CI uses, so the numbers are
# attributable to CI's toolchain (.github/workflows/docker.yml -> esp_idf_version):
#
#   docker run --rm -t \
#     -e IDF_TARGET=esp32s3 \
#     -v "$PWD:/work" -w /work/idf_app \
#     espressif/idf:release-v5.4 \
#     /bin/bash -c 'git config --global --add safe.directory "*" \
#                   && tools/measure/measure_optimization.sh'
#
# In GitHub Actions it is run by the temporary `measure-optimization-202` job
# via espressif/esp-idf-ci-action (esp_idf_version: release-v5.4).
#
# Output goes to a directory inside the mounted repository working tree
# (default: <repo>/optimization-measurements), NOT to the container's /tmp, so
# that a CI job can upload it as an artifact.
#
# Isolation requirements (each one guards against a real contamination path):
#   * separate -B build dir per mode      -> no reuse of another mode's objects
#   * separate -DSDKCONFIG per mode       -> a shared sdkconfig would silently
#                                            carry the previous mode's choice,
#                                            which is the exact failure mode #202
#                                            exists to catch
#   * explicit -DSDKCONFIG_DEFAULTS       -> the -D cache variable overrides
#                                            $ENV{SDKCONFIG_DEFAULTS}
#                                            (tools/cmake/project.cmake:654 sets it
#                                            from the environment, :665-667 then
#                                            overwrite it from the cache variable),
#                                            so an exported SDKCONFIG_DEFAULTS from
#                                            scripts/install.sh cannot leak
#                                            sdkconfig.local into a measurement
#   * IDF_TARGET=esp32s3                  -> a fresh build dir has no target yet,
#                                            and set-target must not be used here
#                                            because it renames an existing
#                                            sdkconfig to sdkconfig.old
#   * RK_ENFORCE_RELEASE_CONFIG=OFF       -> two of the three runs are *supposed*
#                                            to violate the release invariant.
#                                            Harmless before the checker exists
#                                            (CMake only warns that the cache
#                                            variable went unused).
#
# Secrets: idf_app/sdkconfig.defaults contains a tracked credential line. Every
# file this script writes into the output directory is passed through a redactor
# built from the values of credential-shaped CONFIG_ symbols, and no sdkconfig or
# sdkconfig.json file is ever copied into the output directory.
#
set -euo pipefail

MODES="${MODES:-debug size perf}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"      # idf_app/
REPO_DIR="$(cd "${APP_DIR}/.." && pwd)"           # repository root (mounted)

OUT_DIR="${OUT_DIR:-${REPO_DIR}/optimization-measurements}"

cd "$APP_DIR"
mkdir -p "$OUT_DIR"

: "${IDF_TARGET:=esp32s3}"
export IDF_TARGET

# ---------------------------------------------------------------------------
# Redaction. SECRET_FILE lives outside OUT_DIR so it can never be uploaded.
# ---------------------------------------------------------------------------
SECRET_FILE="$(mktemp)"
chmod 600 "$SECRET_FILE"
trap 'rm -f "$SECRET_FILE"' EXIT

if [ -f sdkconfig.defaults ]; then
    grep -E '^CONFIG_[A-Z0-9_]*(PASSWORD|PASSWD|PASS|SECRET|TOKEN|KEY|CRED|PSK)[A-Z0-9_]*=' \
        sdkconfig.defaults 2>/dev/null \
        | sed -E 's/^[^=]*=//; s/^"//; s/"$//' \
        | grep -v '^$' > "$SECRET_FILE" || true
fi

redact() {
    # redact FILE...  -- in-place substitution of any known secret value.
    [ -s "$SECRET_FILE" ] || return 0
    SECRET_FILE="$SECRET_FILE" python3 - "$@" <<'PY'
import os, sys
with open(os.environ["SECRET_FILE"], encoding="utf-8", errors="replace") as fh:
    secrets = [s for s in (line.rstrip("\n") for line in fh) if len(s) >= 4]
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        continue
    new = text
    for secret in secrets:
        new = new.replace(secret, "<redacted>")
    if new != text:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new)
PY
}

# ---------------------------------------------------------------------------
# Provenance. Recorded before any build so it exists even if a build dies.
# ---------------------------------------------------------------------------
echo "=== provenance ==="
{
    echo "measured_for: issue #202"
    echo "repo_commit: $(git -C "$REPO_DIR" rev-parse HEAD 2>&1 || echo unavailable)"
    echo "repo_describe: $(git -C "$REPO_DIR" describe --tags --always --dirty 2>&1 || echo unavailable)"
    echo "idf.py_version: $(idf.py --version 2>&1 | tail -1)"
    echo "IDF_TARGET: ${IDF_TARGET}"
    echo "IDF_PATH: ${IDF_PATH:-unset}"
    if [ -n "${IDF_PATH:-}" ] && [ -e "${IDF_PATH}/.git" ]; then
        echo "idf_describe: $(git -C "${IDF_PATH}" describe --tags --always 2>&1 || echo unavailable)"
        echo "idf_commit: $(git -C "${IDF_PATH}" rev-parse HEAD 2>&1 || echo unavailable)"
    else
        echo "idf_describe: unavailable (no ${IDF_PATH:-IDF_PATH}/.git)"
        echo "idf_commit: unavailable"
    fi
    if [ -f "${IDF_PATH:-/nonexistent}/version.txt" ]; then
        echo "idf_version_txt: $(cat "${IDF_PATH}/version.txt")"
    fi
    echo "compiler: $(xtensa-esp32s3-elf-gcc --version 2>&1 | head -1)"
    echo "compiler_dumpversion: $(xtensa-esp32s3-elf-gcc --dumpversion 2>&1 | tail -1)"
    echo "cmake: $(cmake --version 2>&1 | head -1)"
    echo "ninja: $(ninja --version 2>&1 | head -1)"
    echo "python: $(python3 --version 2>&1)"
    echo "esp-idf-kconfig: $(python3 -c 'import importlib.metadata as m; print(m.version("esp-idf-kconfig"))' 2>&1 | tail -1)"
    echo "kconfiglib: $(python3 -c 'import importlib.metadata as m; print(m.version("kconfiglib"))' 2>&1 | tail -1)"
} | tee "$OUT_DIR/provenance.txt"
redact "$OUT_DIR/provenance.txt"

# ---------------------------------------------------------------------------
# One build per mode.
# ---------------------------------------------------------------------------
for mode in $MODES; do
    echo
    echo "=== building mode: ${mode} ==="
    frag="tools/measure/opt-${mode}.defaults"
    [ -f "$frag" ] || { echo "missing fragment $frag" >&2; exit 1; }

    result="$OUT_DIR/${mode}.result.txt"
    : > "$result"
    echo "mode: ${mode}" >> "$result"

    rm -rf "build-${mode}" "sdkconfig.${mode}"
    set +e
    idf.py -B "build-${mode}" \
           -DSDKCONFIG="sdkconfig.${mode}" \
           -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;${frag}" \
           -DRK_ENFORCE_RELEASE_CONFIG=OFF \
           build > "$OUT_DIR/${mode}.build.log" 2>&1
    rc=$?
    set -e
    redact "$OUT_DIR/${mode}.build.log"
    echo "link_result: rc=${rc}" >> "$result"

    # Prove the fragment actually reached IDF's resolved configuration. Only
    # optimization/assertion symbols are extracted -- the full sdkconfig.json is
    # never copied out, because it contains the tracked credential value.
    cfg="build-${mode}/config/sdkconfig.json"
    if [ -f "$cfg" ]; then
        python3 - "$cfg" >> "$result" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = json.load(fh)
for key in sorted(cfg):
    if "COMPILER_OPTIMIZATION" in key or "COMPILER_ASSERT" in key:
        print(f"effective_CONFIG_{key}: {cfg[key]}")
PY
    else
        echo "effective_config: unavailable (${cfg} missing)" >> "$result"
    fi

    if [ "$rc" -ne 0 ]; then
        echo "--- last 40 lines of build log ---"
        tail -40 "$OUT_DIR/${mode}.build.log"
        # A link failure is itself a valid measurement outcome: the decision
        # rule requires the chosen mode to link with static DRAM headroom.
        redact "$result"
        cat "$result"
        continue
    fi

    # DRAM/IRAM totals and per-component breakdown.
    idf.py -B "build-${mode}" size            > "$OUT_DIR/${mode}.size.txt" 2>&1 || true
    idf.py -B "build-${mode}" size-components > "$OUT_DIR/${mode}.size-components.txt" 2>&1 || true
    if ! idf.py -B "build-${mode}" size --format json > "$OUT_DIR/${mode}.size.json" 2>/dev/null; then
        rm -f "$OUT_DIR/${mode}.size.json"
    fi
    redact "$OUT_DIR/${mode}.size.txt" "$OUT_DIR/${mode}.size-components.txt"
    if [ -f "$OUT_DIR/${mode}.size.json" ]; then
        redact "$OUT_DIR/${mode}.size.json"
    fi

    # Pull the headline DRAM/IRAM figures into the per-mode result file so the
    # summary is readable without opening the full size report.
    grep -iE 'dram|iram|flash code|flash data|total image size' \
        "$OUT_DIR/${mode}.size.txt" 2>/dev/null | sed 's/^/size_line: /' >> "$result" || true

    bin="build-${mode}/roon_knob.bin"
    if [ -f "$bin" ]; then
        bytes=$(stat -c %s "$bin" 2>/dev/null || wc -c < "$bin")
        bytes="${bytes//[[:space:]]/}"
        echo "bin_bytes: ${bytes}" >> "$result"
        # 0x280000 = 2621440 = one app partition slot (idf_app/partitions.csv)
        python3 -c "print('app_partition_pct: %.2f%%' % (${bytes} / 0x280000 * 100))" >> "$result"
    else
        echo "bin_bytes: unavailable" >> "$result"
    fi

    redact "$result"
    echo "--- ${mode} result ---"
    cat "$result"
    echo "--- ${mode} size ---"
    cat "$OUT_DIR/${mode}.size.txt"
done

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
{
    echo "# Optimization measurement (#202)"
    echo
    echo '## provenance'
    echo
    sed 's/^/    /' "$OUT_DIR/provenance.txt"
    echo
    for mode in $MODES; do
        echo "## ${mode}"
        echo
        sed 's/^/    /' "$OUT_DIR/${mode}.result.txt" 2>/dev/null || echo "    (no result)"
        echo
    done
} > "$OUT_DIR/summary.md"
redact "$OUT_DIR/summary.md"

echo
echo "=== summary ==="
cat "$OUT_DIR/summary.md"
echo
echo "Artifacts in ${OUT_DIR}"
