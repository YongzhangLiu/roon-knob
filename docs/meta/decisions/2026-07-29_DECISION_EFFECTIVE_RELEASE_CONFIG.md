# Decision: enforce the *effective* firmware release configuration

**Date:** 2026-07-29
**Issue:** [#202](https://github.com/muness/roon-knob/issues/202) (parent [#189](https://github.com/muness/roon-knob/issues/189), program [#201](https://github.com/muness/roon-knob/issues/201), epic [#196](https://github.com/muness/roon-knob/issues/196))
**Status:** Accepted, implementation landed
**Supersedes (partially):** the release-safety role of the `sdkconfig.defaults` staleness guard from closed #149

## Context

The original task was "add the missing performance-optimization line to `sdkconfig.defaults`."
That framing is wrong in a way worth writing down, because it will recur.

`sdkconfig.defaults` is an **input**, not a record of what was built. It can be:

* **stale** — an existing `idf_app/sdkconfig` takes precedence, so a newly added default is silently ignored (this is exactly what #149 was created for);
* **undefined** — a symbol that no longer exists is accepted, ignored, and warned about in a line nobody reads;
* **overridden** — `sdkconfig.local`, `SDKCONFIG_DEFAULTS`, `sdkconfig.override`, and `-D` cache variables all change the outcome;
* **incomplete** — most of the resolved configuration comes from IDF's own Kconfig defaults, which change with the SDK.

So the file cannot prove what the compiler actually used. Adding one line to it would have produced a release build that *probably* was optimized. IDF, however, writes the fully resolved configuration to `build/config/sdkconfig.json` during `project()`. That artifact **can** prove it.

The reframe: **enforce a small release policy against IDF's generated effective configuration**, and treat committed defaults as merely one input to it.

## Decision

1. A dependency-free checker, `idf_app/tools/check_release_config.py`, validates declared release invariants against an explicitly named `sdkconfig.json`, emits stable `RK-RELCFG-*` tokens and a JSON report, and identifies its own failure modes rather than passing silently.
2. `idf_app/cmake/rk_release_config.cmake`, included **after** `project()`, runs the checker at configure time, always writes the report, always prints a banner, and defers failure via `fail_at_build_time()`.
3. CI forces enforcement **on** through the ci-action's `command:` input and then **asserts the report on the host**.
4. Undefined-symbol detection is **delegated to kconfgen**, not reimplemented.
5. Negative proof lives in committed fixtures plus exactly one integration build.
6. #149's guard is restored, with its limited local purpose documented rather than overstated.

## The measurement that chose the optimization mode

#202's soft constraint was explicit: the optimized mode must be **selected from measurement**, not inherited from the v4 branch. Inheriting is what produced the original bug.

All three modes were built on **CI's own toolchain**, in the same container image the release build uses, from three isolated build directories with three isolated `sdkconfig` files and explicit `-DSDKCONFIG_DEFAULTS` per build. Run: GitHub Actions `30498910795`, pull request #204 (draft, measurement only).

### Provenance

| Item | Value |
|---|---|
| Image | `espressif/idf:release-v5.4` (mutable tag — see the ceiling below) |
| `idf.py --version` | `ESP-IDF v5.4.4-1000-g8543b57cf15` |
| IDF commit | `8543b57cf15853fd8648cb12e63a1b0e7ea4075b` |
| Compiler | `xtensa-esp-elf-gcc (crosstool-NG esp-14.2.0_20260121) 14.2.0` |
| `esp-idf-kconfig` | 2.5.4 |
| CMake / Ninja / Python | 3.30.2 / 1.11.1 / 3.12.3 |
| Target | `esp32s3` (passed as `IDF_TARGET` per build; `set-target` deliberately not used) |
| Source | PR #204 merge commit `55e9d5d3e25ffb9c0684d30840db586b2b330f99`; attributable branch head `82f36a62b04bc8623d3ce93516e65d03f8a2fd0b` |

### Results

| Mode | Link | `roon_knob.bin` | % of `0x280000` app slot | Flash code | Flash data | Static DIRAM | DIRAM free | IRAM | Effective symbol |
|---|---|---|---|---|---|---|---|---|---|
| DEBUG (`-Og`) | ok | 1 761 952 B | 67.21 % | 1 099 598 | 523 160 | 222 931 (65.23 %) | 118 829 | 16 383 | `COMPILER_OPTIMIZATION_DEBUG=true` |
| **SIZE (`-Os`)** | **ok** | **1 613 984 B** | **61.57 %** | **974 124** | **511 104** | **212 259 (62.11 %)** | **129 501** | **16 383** | `COMPILER_OPTIMIZATION_SIZE=true` |
| PERF (`-O2`) | ok | 1 765 520 B | 67.35 % | 1 112 020 | 518 268 | 219 007 (64.08 %) | 122 753 | 16 383 | `COMPILER_OPTIMIZATION_PERF=true` |

Each run's effective mode was read back from that build's own `build/config/sdkconfig.json`, which is how we know the fragment reached the resolved configuration rather than merely the defaults file.

### Decision rule and outcome

The rule, applied in order: (1) the mode must link with non-zero static DRAM headroom; (2) prefer the smallest image, because the app partition is a fixed `0x280000` slot and OTA needs two of them; (3) break ties on static DIRAM headroom, because DRAM exhaustion is the failure mode this device actually hits.

All three modes link. **SIZE wins outright**: smallest image (−147 968 B vs DEBUG, −151 536 B vs PERF) *and* lowest static DIRAM (−10 672 B vs DEBUG, −6 748 B vs PERF), at identical IRAM. No trade-off had to be adjudicated, which is a stronger result than the rule anticipated. Note also that PERF is *larger and hungrier* than DEBUG here while being the mode the original one-line framing would have added — a concrete example of why the measurement was made a precondition.

`sdkconfig.defaults` therefore carries `CONFIG_COMPILER_OPTIMIZATION_SIZE=y`.

### Why the gate does not pin SIZE

The invariant is deliberately looser than the measurement: **exactly one of `COMPILER_OPTIMIZATION_SIZE` / `COMPILER_OPTIMIZATION_PERF` true, and `COMPILER_OPTIMIZATION_DEBUG` / `COMPILER_OPTIMIZATION_NONE` false.**

The gate's job is "this build is optimized," which is the property that was actually violated. Encoding "SIZE specifically" would mean a hardware-driven SIZE↔PERF switch in #203 requires editing the gate, its fixtures, and this record — three places to say one thing. The measured choice lives in `sdkconfig.defaults`, where changing it is a one-line diff that the gate still checks.

## Invariants asserted

Every symbol name and expected default below was verified **against IDF commit `8543b57cf15`** — the exact tree CI built with — not against a local checkout.

| Invariant | Expected | Why | Verified at |
|---|---|---|---|
| `COMPILER_OPTIMIZATION` choice | exactly one of SIZE/PERF; never DEBUG/NONE | the release must be optimized | `Kconfig:345-351` |
| `COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE` | true | OTA field devices, no crash-reporting channel; pins IDF's own default | `Kconfig:370` |
| `SPIRAM` | true | artwork RGB565 buffers do not fit without PSRAM | `esp_psram/esp32s3/Kconfig.spiram:1` |
| `PARTITION_TABLE_CUSTOM` | true | OTA layout comes from `partitions.csv` | `partition_table/Kconfig.projbuild:61` |
| `HEAP_POISONING_DISABLED` | true | debug-only cost; IDF default | `heap/Kconfig:12` |
| `HEAP_TRACING_OFF` | true | permanent IRAM + malloc overhead; IDF default | `heap/Kconfig:30` |
| `COMPILER_DUMP_RTL_FILES` | false | debug-only compiler output | `Kconfig:597` |
| `ESP_DEBUG_STUBS_ENABLE` | false | debug-only on-target stubs | `esp_system/Kconfig:529` |
| `ESP_SYSTEM_PANIC_GDBSTUB` | false | a field device must reboot, not wait for gdb | `esp_system/Kconfig:39` |
| `FREERTOS_USE_TRACE_FACILITY` | false | debug-only scheduler bookkeeping | `freertos/Kconfig:256` |
| `ESPTOOLPY_FLASHSIZE` | `"16MB"` | must match what the committed defaults declare | `esptool_py/Kconfig.projbuild:136` |

**Nothing was written into `sdkconfig.defaults` merely because it happens to be true today.** The five "inherited IDF default" symbols are checker assertions, not new default lines. The only line added to that file is the measured optimization choice.

### Absence is directional, and that is deliberate

IDF omits a symbol from `sdkconfig.json` when it is not written out, so "key missing" is ambiguous in general but unambiguous per direction:

* expected **true** and absent → **violation**. Not written out means not enabled.
* expected **false** and absent → **satisfied**. Same reasoning, opposite sign.
* the **entire optimization choice family** absent → `RK-RELCFG-UNDEFINED` (exit 4). That is not a configuration error; it means the symbol names moved out from under the checker, and it must not read as a pass.

This is what keeps "absent ≠ pass" honest without manufacturing false positives out of IDF's own visibility semantics.

### Not asserted here

Image size, DRAM headroom thresholds, partition geometry, the merged-image header, `--flash-size` direction, `PROJECT_VER` binary inspection, and toolchain identity. Those belong to #203 / #183.

## Undefined defaults: delegated to kconfgen, not reimplemented

`esp-idf-kconfig` already decides "this assignment names a symbol that does not exist," on the exact input file, with correct alias/rename semantics, and prints:

```
warning: unknown kconfig symbol 'SYM' assigned to 'VALUE' in FILE
```

An earlier review proposed reconstructing that determination from three build artifacts (`sdkconfig.json` + `sdkconfig.h` + `kconfig_menus.json`) with its own exit code. That was **rejected**, and the record is corrected here because it is load-bearing for anyone revisiting this:

* The string is emitted by **kconfgen** (`kconfgen/core.py`, defaults-loading path), **not** kconfiglib.
* It is **not version-fragile** across the range `release-v5.4` can resolve to: `espidf.constraints.v5.4.txt` pins `esp-idf-kconfig>=2.0.2,<3.0.0`, and the format string is byte-identical in all eleven in-range 2.x releases (2.0.2 → 2.5.4).
* `ignore_build_warnings.txt` is **live suppression that IDF's own CI depends on**, not legacy residue.
* kconfgen's verdict is **visibility-independent and alias-correct**: `missing_syms` is appended only for genuinely undefined symbols (`not sym.nodes`), and renames are excluded by consulting the `sdkconfig.rename` files directly.
* **#202's acceptance criterion as originally worded was accurate.** The "correction" away from it was the error.

So the checker **consumes** that line (`--log`) and never re-derives it. Two consequences worth stating:

* **The value is never captured.** The regex stops before the assigned value, because `sdkconfig.defaults` historically carried a credential and a gate must not become an exfiltration path. A fixture asserts the value never appears in output.
* **This layer is enforced in CI, not at configure time.** `kconfig.cmake` does not capture kconfgen's stdout, so the configure-time run's warnings are not available to the checker without re-invoking kconfgen. Rather than re-run it with reconstructed arguments, CI tees the build log and scans it. Locally, an undefined default warns (kconfgen's own output) but does not fail. That is an honest ceiling, not an oversight.

### Removed lines

Confirmed by kconfgen **in the CI container** (measurement logs, all three builds): exactly four distinct undefined symbols, across five lines, all now removed —

| Old line | Symbol | Note |
|---|---|---|
| 1 | `CONFIG_WIFI_SSID` | never referenced by any source file |
| 2 | `CONFIG_WIFI_PASSWORD` | never referenced; had no effect on any build |
| 3 | `CONFIG_EXAMPLE_IPV6` | leftover from an IDF example |
| 33 | `CONFIG_LWIP_NETIF_HOSTNAME` | not an IDF symbol; hostname comes from `CONFIG_LWIP_LOCAL_HOSTNAME` |
| 85 | `CONFIG_LWIP_NETIF_HOSTNAME` | duplicate of line 33 |

**Retained deliberately:** the four brownout rename aliases (old lines 41–44). kconfgen reports these as `was replaced with`, i.e. *renames*, not unknown symbols, and the level-4 / 2.50 V tuning they carry exists because level 7 caused boot failures on battery from Wi-Fi inrush. A fixture asserts that rename lines do **not** trip the gate.

Note on line 2: it is removed because kconfgen proves it is undefined and inert, **not** as credential remediation. The value remains in git history, and history/credential remediation stays out of scope for #202 (private operational track). `idf_app/sdkconfig.override` was not read, modified, or staged.

## Mechanism details worth recording

### `SDKCONFIG_DEFAULTS` precedence — corrected

`tools/cmake/project.cmake:654` seeds `_sdkconfig_defaults` from `$ENV{SDKCONFIG_DEFAULTS}`, and `:665-667` then overwrite it from the `-D` **cache variable**. So `-DSDKCONFIG_DEFAULTS` **wins over the environment**. This matters twice: it is why the measurement's isolation against `scripts/install.sh`'s exported `sdkconfig.defaults;sdkconfig.local` was real rather than redundant, and it is one of the override paths that makes the defaults file untrustworthy as evidence.

### Why `fail_at_build_time()` and not `FATAL_ERROR`

`FATAL_ERROR` at configure time wedges `idf.py menuconfig`, which is one of the two documented recovery paths — the gate would block the tool you need to fix what it is complaining about. `fail_at_build_time()` instead fails `idf.py build` while leaving `menuconfig` (a non-`ALL` custom target) and `reconfigure` working, and it deletes its own stamp so the next invocation re-evaluates. Both recovery paths — fix it in `menuconfig`, or `rm sdkconfig && idf.py build` — are reachable **without** touching the escape hatch, which is what stops the opt-out from becoming the path of least resistance.

Two hardening requirements at the call site, both verified as real and both implemented:

* `fail_at_build_time(target, message_line0)` takes `message_line0` as a **required positional**, so an empty capture would become a configure-time CMake argument error — the exact hard failure the design avoids. The CMake wiring guarantees a non-empty first line.
* the helper does `foreach(line ${ARGN})`, which **splits on `;`**. The checker strips `;` from its output and the CMake wiring replaces any remaining `;` with `,`.

### Why `command:`-forcing over `extra_docker_args`

`CI` does not cross into the container, so enforcement cannot be inherited from the environment. Putting `-DRK_ENFORCE_RELEASE_CONFIG=ON` on the `idf.py` command line via the action's `command:` input makes the forcing **visible in the workflow diff** — an `-e` in `extra_docker_args` is both easier to miss in review and easier to drop silently.

### Enforcement ceilings — stated plainly

"CI cannot opt out" is true only with the host assertion, and even then it has edges:

1. `fail_at_build_time()` creates an `ALL` target, so the gate fires for `idf.py build` but **not** for target-selected invocations such as `idf.py app`. A developer can produce a `roon_knob.bin` locally with the gate never running. Local coverage is ergonomic, not absolute.
2. The host assertion catches a flipped flag, a deleted checker, and a removed CMake call. It does **not** catch **deletion of the assertion step itself**, and nothing in-repo can. Closing that requires branch protection with required checks — out of repo, and not touched by #202.
3. `espressif/idf:release-v5.4` is a **mutable tag**. The measurement table above is attributable to `v5.4.4-1000-g8543b57cf15` / GCC 14.2.0 because those were recorded, but a future run of the same workflow may resolve to a different commit. Recording is not pinning; SDK pinning is #183/#203. If the numbers are ever re-derived, re-record the provenance rather than assuming this table still applies.

### `ESPTOOLPY_FLASHSIZE` = 16MB vs the 8MB merge — deliberately unresolved

`sdkconfig.defaults` declares `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"` while `.github/workflows/docker.yml`'s `esptool merge-bin` step passes `--flash-size 8MB`. That disagreement is real. #202 asserts the config value **only at what the committed defaults already declare**, touches no image header, and takes **no position** on the correct direction. Resolving it belongs to **#203** (with #193 for hardware identity).

### `sdkconfig.defaults.ble`

Invariants are declared for the default profile only. `sdkconfig.defaults.ble` is a manual, non-CI profile that flips `BT_ENABLED` / `ROON_KNOB_BLE_HID_ENABLED` and touches none of the asserted symbols. The checker's explicit `--config` path is the seam a future profile would use; **no profile mechanism is built here** (that is #200).

## Negative proof

| Layer | What only it can prove | Cost |
|---|---|---|
| `tools/fixtures/` + `tools/test_check_release_config.sh` (CI job `release-config-fixtures`) | the checker's logic: exact exit code and exact token per case, positive and negative, including that rename aliases pass and that assigned values are never echoed | host-only, seconds |
| assert-the-assertion cases in the same runner | that the host gate has teeth: it rejects `enforced:false`, a digest belonging to another build, a missing report, and a failing verdict | host-only, folded in rather than a separate job |
| CI job `build-stale-config` | the wiring: a stale `sdkconfig` that ignores the committed defaults is caught at configure time, for the stated reason | one container build |

`build-stale-config` requires **all three** of: step outcome `failure`, the exact token `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG` in the log, and a report with `verdict:"fail"`. An unrelated compile break yields the first but not the other two, so it goes red as a red herring rather than passing as a false proof. It never calls `set-target`, which would rename the seeded `sdkconfig` to `sdkconfig.old` and destroy the condition under test.

Exit codes are contract, asserted by fixtures: `0` OK, `2` violation, `3` no/malformed config, `4` undefined, `64` usage error (distinct from every verdict).

## #149's guard: restored and re-scoped

The `sdkconfig.defaults` staleness guard from closed #149 is restored in `idf_app/CMakeLists.txt`, essentially verbatim, with two documented decisions:

* **It keeps `FATAL_ERROR`**, unlike the config gate, because its recovery is `rm sdkconfig && idf.py build` and does not require `menuconfig` to still work. The asymmetry is deliberate.
* **Its scope is stated honestly.** It hashes `sdkconfig.defaults` and requires **both** an existing `idf_app/sdkconfig` **and** a stamp in the build dir, so it is silent on a fresh CI checkout, and `scripts/install.sh`'s `rm sdkconfig` bypasses it. It is a **local developer-ergonomics guard**; its release-safety role is **superseded** by the effective-config gate, which fires where the guard cannot.

It is restored rather than merely superseded because of one non-substitutable contribution: `set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_DEFAULTS_FILE}")`. IDF registers `sdkconfig`, `sdkconfig.h` and `sdkconfig.cmake` as configure dependencies but **not** `sdkconfig.defaults`, so without that line editing the defaults would not re-run configure and the new gate would not re-evaluate. The gate's own CMake file registers the same dependency plus the checker, so the two mechanisms are complements: the guard tells a developer their `sdkconfig` is stale, the gate tells anyone what the build actually resolved.

## Alternatives rejected

| Option | Why rejected |
|---|---|
| **A — add the one missing line** | Leaves every failure mode above intact: the next stale `sdkconfig` silently ships a debug build. It is the framing that produced the bug. |
| **B — assert on `sdkconfig.defaults`** | Validates the input, not the outcome. Passes while the build resolves to something else entirely. |
| **C — post-build binary/image inspection** | Late, indirect, and mostly #203's territory. Cannot distinguish "unoptimized" from "differently linked" without a size oracle. |
| **E — rely on kconfgen warnings alone** | Warnings do not fail builds, and they say nothing about the invariants that matter (SPIRAM, panic handler, assertions). Kept for exactly the one determination it is authoritative about. |
| **Reconstruct undefined-symbol detection from three artifacts** | Rebuilds, less correctly, a verdict the toolchain already emits. See above. |

## Consequences

* A release build that resolves to a debug or unsafe configuration now fails, at configure time, naming the symbol.
* CI's enforcement is provable from an artifact rather than assumed from a workflow line.
* The optimization mode is now a recorded measurement, so the next maintainer does not have to guess whether it was reasoned or copied.
* `roon_knob.bin` shrinks from 1 761 952 B to 1 613 984 B (67.21 % → 61.57 % of the app slot) and static DIRAM drops 10 672 B. This is a **behavioural change** — `-Og` → `-Os` — and CI cannot validate it. It interacts with the brownout tuning above.
* Hardware validation is release-blocking but **not** merge-blocking: #202 merges on contract/CI evidence; #203's PR build (containing both #202 and #203) is the single combined hardware-test candidate; the release-blocking checklist lives on #189 and blocks **tagging**, not merging.
* New CI surface: enforcement forcing plus two host assertions in `build-idf`, one host fixture job, and one integration build. The known adoption risk is that a red-for-infrastructure-reasons job gets `continue-on-error` or is quietly dropped during #203's workflow edit. The fixtures job is seconds and host-only specifically to keep that pressure low.

## References

* Checker: `idf_app/tools/check_release_config.py`
* Host assertion: `idf_app/tools/assert_release_report.py`
* Fixtures + runner: `idf_app/tools/fixtures/`, `idf_app/tools/test_check_release_config.sh`
* CMake wiring: `idf_app/cmake/rk_release_config.cmake`; #149 guard in `idf_app/CMakeLists.txt`
* CI: `.github/workflows/docker.yml` (`build-idf`, `release-config-fixtures`, `build-stale-config`)
* Measurement run: GitHub Actions `30498910795`, draft PR #204
