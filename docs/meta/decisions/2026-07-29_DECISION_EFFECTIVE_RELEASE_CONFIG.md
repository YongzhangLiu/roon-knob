# Decision: enforce the *effective* firmware release configuration

**Date:** 2026-07-29
**Issue:** [#202](https://github.com/muness/roon-knob/issues/202) (parent [#189](https://github.com/muness/roon-knob/issues/189), program [#201](https://github.com/muness/roon-knob/issues/201), epic [#196](https://github.com/muness/roon-knob/issues/196))
**Status:** Accepted; implemented and enforced from this commit.

**Observed:** the host half, and reproducibly so — both suites are committed and both run in `release-config-fixtures`, so these are not one-off scratch runs:

* `tools/test_check_release_config.sh` — the checker and the host asserter: exit contract, token precedence in both directions, absence-directionality, secret non-leakage, assert-the-assertion, caller-owned marker, empty-argument contract, and the tripwire that the CI-only canary is not committed.
* `tools/test_release_config_cmake.sh` — the **gate** itself, running under `cmake -P` with IDF's two commands stubbed: compliant-pass, ON-violation-fails, OFF-violation-continues (with banner and `enforced:false`/`verdict:fail` report), `NOCHECKER`, empty-output-synthesizes-a-non-empty-first-line, `;`→`,`, `NOREPORT`, an unlaunchable interpreter (the non-numeric `RESULT_VARIABLE` case that `STREQUAL "0"` exists for), and a missing `fail_at_build_time` (which must fail attributably with `RK-RELCFG-NOHELPER` rather than reaching CMake's unlabelled "Unknown CMake command" at the exact moment the gate is trying to block a build). An earlier revision of this record cited an *uncommitted* harness for these, which by this record's own standard was a claim that could not be checked from the tree.
Only those two suites are committed and re-runnable, and only they support this Status line.

Separately, and **not** evidence in the same sense: before landing, each host `run:` step in `build-idf`, `build-stale-config` and `release` was exercised by hand against a simulated runner — a root-owned read-only `build/config`, a missing report, a wrong log, differing ON/OFF digests, the mode-agnostic seed against synthetic SIZE- and PERF-selected defaults, and the canary both passing and failing on a reworded warning. Those checks were scratch scripts extracted from the workflow, not committed fixtures: they informed the design and caught real defects, but nobody can re-run them from this tree, so they are recorded here as provenance rather than counted as coverage. The workflow's own host steps get their standing coverage from CI itself, once it runs.

**Pending:** the container half. No ESP-IDF build — and therefore neither the real configure-time gate nor `build-stale-config`'s ON/OFF pair — has executed in CI at the time of writing. Backfill the run ID here once PR #204 carries this commit and all four surfaces are green, and replace this note with the observed result.
**Supersedes (partially):** the release-safety role of the `sdkconfig.defaults` staleness guard from closed #149

## Context

The original task was "add the missing performance-optimization line to `sdkconfig.defaults`."
That framing is wrong in a way worth writing down, because it will recur.

`sdkconfig.defaults` is an **input**, not a record of what was built. It can be:

* **stale** — an existing `idf_app/sdkconfig` takes precedence, so a newly added default is silently ignored (this is exactly what #149 was created for);
* **undefined** — a symbol that no longer exists is accepted, ignored, and warned about in a line nobody reads;
* **overridden** — `sdkconfig.local` (wired by `scripts/install.sh`, which exports `SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.local"`), the `SDKCONFIG_DEFAULTS` environment variable, and `-D` cache variables all change the outcome. (`idf_app/sdkconfig.override` exists in the tree but is **not** a wired override path: nothing in this repo passes it to IDF and IDF does not read it on its own. It is named here only to correct an earlier draft of this record that listed it as one. It was not read, modified, or staged by this work.)
* **incomplete** — most of the resolved configuration comes from IDF's own Kconfig defaults, which change with the SDK.

So the file cannot prove what the compiler actually used. Adding one line to it would have produced a release build that *probably* was optimized. IDF, however, writes the fully resolved configuration to `build/config/sdkconfig.json` during `project()`. That artifact **can** prove it.

The reframe: **enforce a small release policy against IDF's generated effective configuration**, and treat committed defaults as merely one input to it.

## Decision

1. A dependency-free checker, `idf_app/tools/check_release_config.py`, validates declared release invariants against an explicitly named `sdkconfig.json`, emits stable `RK-RELCFG-*` tokens and a JSON report, and identifies its own failure modes rather than passing silently.
2. `idf_app/cmake/rk_release_config.cmake`, included **after** `project()`, runs the checker at configure time, always writes the report, always prints a banner, and defers failure via `fail_at_build_time()`.
3. CI forces enforcement **on** through the ci-action's `command:` input and then **asserts the report on the host**, including that the build log the undefined-symbol scan read is the one the gate wrote.
4. Undefined-symbol detection is **delegated to kconfgen**, not reimplemented — and a requested-but-missing verdict is a failure, not silence.
5. Negative proof lives in committed fixtures plus exactly one integration build, and both **gate** shipping via `release`'s `needs:` rather than merely reporting.
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

### The limit of this measurement — read this before quoting "chosen by measurement"

Every metric above is **static**: link success, image bytes, static DIRAM/IRAM. There is **no dynamic datapoint**. `-Og` → `-Os` is a behavioural change on a device whose felt qualities are encoder responsiveness and LVGL redraw smoothness, and nothing here measured either. "Chosen by measurement" must never be read as "chosen by performance measurement."

What makes that acceptable rather than reckless is reversibility: the gate accepts SIZE **or** PERF, so switching is a one-line `sdkconfig.defaults` diff that the gate still checks — no gate, fixture, workflow, or ADR edit required.

That claim is only true because it was made true. An earlier revision of `build-stale-config` matched the literal `CONFIG_COMPILER_OPTIMIZATION_SIZE=y` line when seeding its stale tree, so flipping the default to PERF would have failed that job at its seed step with `found 0` — and since the job gates tagging, the "one-line" switch would silently have been a two-place edit that blocks a release. The seed now matches whichever release mode is selected (`^CONFIG_COMPILER_OPTIMIZATION_(SIZE|PERF)=y$`) while keeping the `exactly one` tripwire, so two selected modes or none still stops the job loudly. Verified against synthetic SIZE-selected and PERF-selected defaults, and against both tripwire cases.

**#203's combined hardware test must therefore include, as named items:**

1. **Encoder input latency** at `-Os` — rotation-to-visible-response, including fast continuous rotation.
2. **LVGL redraw** — artwork transitions and screen changes; watch for dropped frames or tearing that `-Og` did not show.
3. **Battery brownout behaviour at `-Os`** against the level-4 / 2.50 V tuning, on battery, including Wi-Fi association inrush (the condition that made level 7 unusable).
4. **Boot and OTA from a prior release** built at `-Og`, to confirm the mode change does not interact with the update path.

If any of those regress, the remedy is the one-line switch to PERF (which costs ~151 KB of image and ~7 KB of DIRAM against SIZE, per the table above), not reverting the gate.

### Why the gate does not pin SIZE

The invariant is deliberately looser than the measurement: **exactly one of `COMPILER_OPTIMIZATION_SIZE` / `COMPILER_OPTIMIZATION_PERF` true, and `COMPILER_OPTIMIZATION_DEBUG` / `COMPILER_OPTIMIZATION_NONE` false.**

The gate's job is "this build is optimized," which is the property that was actually violated. Encoding "SIZE specifically" would mean a hardware-driven SIZE↔PERF switch in #203 requires editing the gate, its fixtures, and this record — three places to say one thing. The measured choice lives in `sdkconfig.defaults`, where changing it is a one-line diff that the gate still checks.

## Invariants asserted

Every symbol name and expected default below was verified **against IDF commit `8543b57cf15`** — the exact tree CI built with — not against a local checkout. References are given as *symbol declarations in named files*, deliberately **not** as `Kconfig:NNN` line anchors: those drift with every SDK bump and were already stale against a locally installed v5.5.3 within a day of being written. Locate with `grep -rn "^ *config <SYMBOL>$" $IDF_PATH/components/`.

| Invariant | Expected | Why | Declared in |
|---|---|---|---|
| `COMPILER_OPTIMIZATION` choice | exactly one of SIZE/PERF; never DEBUG/NONE | the release must be optimized | root `Kconfig`, `choice COMPILER_OPTIMIZATION` |
| `COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE` | true | OTA field devices, no crash-reporting channel; pins IDF's own default | root `Kconfig`, `choice COMPILER_OPTIMIZATION_ASSERTION_LEVEL` (first member = default) |
| `SPIRAM` | true | artwork RGB565 buffers do not fit without PSRAM | `esp_psram/esp32s3/Kconfig.spiram` |
| `PARTITION_TABLE_CUSTOM` | true | OTA layout comes from `partitions.csv` | `partition_table/Kconfig.projbuild` |
| `HEAP_POISONING_DISABLED` | true | debug-only cost; IDF default | `heap/Kconfig`, `choice HEAP_CORRUPTION_DETECTION` (`default HEAP_POISONING_DISABLED`) |
| `HEAP_TRACING_OFF` | true | permanent IRAM + malloc overhead; IDF default | `heap/Kconfig`, `choice HEAP_TRACING_DEST` (`default HEAP_TRACING_OFF`) |
| `COMPILER_DUMP_RTL_FILES` | false | debug-only compiler output | root `Kconfig` |
| `ESP_DEBUG_STUBS_ENABLE` | false | debug-only on-target stubs | `esp_system/Kconfig` — see the note below; its default expression is **not** what an earlier revision of this record claimed |
| `ESP_SYSTEM_PANIC_GDBSTUB` | false | a field device must reboot, not wait for gdb | `esp_system/Kconfig`, `choice ESP_SYSTEM_PANIC` (non-default member) |
| `FREERTOS_USE_TRACE_FACILITY` | false | debug-only scheduler bookkeeping | `freertos/Kconfig` (`default n`; selected only by `FREERTOS_GENERATE_RUN_TIME_STATS`, itself `default n`) |
| `ESPTOOLPY_FLASHSIZE` | `"16MB"` | must match what the committed defaults declare | `esptool_py/Kconfig.projbuild` (string, defaulted from the `ESPTOOLPY_FLASHSIZE_*` choice) |

**`ESP_DEBUG_STUBS_ENABLE`, stated conservatively.** An earlier revision said its default "tracks the debug optimization level, so choosing SIZE satisfies this as a side effect." That reasoning does not hold. At commit `8543b57cf15` the declaration reads `default COMPILER_OPTIMIZATION_LEVEL_DEBUG` — and `COMPILER_OPTIMIZATION_LEVEL_DEBUG` is **not a declared symbol** anywhere we inspected at that commit (root `Kconfig`, `esp_system/Kconfig`, `esp_common/Kconfig`, `freertos`, `heap`, `esp_psram`, `partition_table`, `esptool_py`). It appears only in the root `sdkconfig.rename` as a legacy input alias mapping `CONFIG_COMPILER_OPTIMIZATION_LEVEL_DEBUG → CONFIG_COMPILER_OPTIMIZATION_DEBUG`. Rename files translate *sdkconfig inputs*; they do not resolve names inside Kconfig expressions. So what the source says is: the default expression references a legacy name that is not a symbol in this tree, which in kconfiglib makes the default evaluate to `n` irrespective of the optimization choice.

Either way the invariant is satisfied and cannot false-positive — the expectation is `false`, and absence is treated as satisfied for `false`-expected symbols — but the *reason* is "the default is unconditionally n", not "SIZE implies it". **The resolved value itself remains unobserved** and will be visible in the first real CI report's `invariants` rows; this note should be updated from that observation rather than from further source reading.

**Nothing was written into `sdkconfig.defaults` merely because it happens to be true today.** The "inherited IDF default" symbols are checker assertions, not new default lines. The only line added to that file is the measured optimization choice.

### Why inherited defaults are asserted but not declared — and what a failure means

Four of these invariants (`COMPILER_OPTIMIZATION_ASSERTIONS_ENABLE`, `HEAP_POISONING_DISABLED`, `HEAP_TRACING_OFF`, and the `false` debug symbols) pin values the repo never writes down, over a **mutable** `release-v5.4` tag. That combination is a deliberate choice, and the objection to it is fair enough to answer explicitly rather than leave implied.

Writing those values into `sdkconfig.defaults` was **excluded by the accepted phase-1 adjustment** ("nothing is written into `sdkconfig.defaults` merely because it is true today"), for a good reason: a committed line asserting an IDF default is indistinguishable, six months later, from a deliberate project decision, and it silences precisely the signal we want. Pinning the SDK to an immutable tag was **also excluded** — all SDK version selection and pinning is #183, and #202 changing `esp_idf_version` would quietly take over another issue's one-way door.

So the intended semantics are: **an invariant failure under a moved `release-v5.4` is drift detection working, not the gate malfunctioning.** If an upstream default flips, `build-idf` goes red naming the symbol, and the correct response is to *remeasure and review* — decide whether the new upstream default is right for this device, then either accept it (adjust the invariant, recording why) or declare the value explicitly (making it a project decision, recording why). What must not happen is `continue-on-error`, deleting the step, or adding a blanket allowlist. The cost of this design is a possible red build on an unrelated PR; the benefit is that a silent upstream behaviour change cannot reach users' devices unnoticed. That trade was made knowingly.

Immutable SDK selection remains **#183**. When it lands, this whole class of failure becomes a deliberate, reviewed event at version-bump time instead of an ambient risk — which is the right place for it.

### Absence is directional, and that is deliberate

IDF omits a symbol from `sdkconfig.json` when it is not written out, so "key missing" is ambiguous in general but unambiguous per direction:

* expected **true** and absent → **violation**. Not written out means not enabled.
* expected **false** and absent → **satisfied**. Same reasoning, opposite sign.
* the **entire optimization choice family** absent → `RK-RELCFG-UNDEFINED` (exit 4). That is not a configuration error; it means the symbol names moved out from under the checker, and it must not read as a pass.

This is what keeps "absent ≠ pass" honest without manufacturing false positives out of IDF's own visibility semantics.

The same principle governs a **requested but unreadable log**: `--log` is how kconfgen's undefined-symbol verdict reaches the checker, so an absent, unreadable or empty log is `RK-RELCFG-NOLOG` (exit 5), never silence. Passing no `--log` is different and legitimate — the determination is simply not requested, which is the configure-time gate's case — and never fails on that basis. In CI the log is additionally required to contain `RK-RELCFG-VERDICT:`, which proves the log read is the one the gate itself wrote rather than some other file that happened to exist.

And the same principle again for the **report**: a `--report` that was requested but could not be written is `RK-RELCFG-NOREPORT` (exit 6), and the `OK` token is withdrawn so no passing verdict can be printed after failing to produce the artifact CI audits. A determination that cannot be recorded is not a trustworthy pass. The report is written atomically (temp file plus rename) so a failure partway through cannot leave a truncated file for a later reader to parse as a pass. Passing no `--report` is, again, different and legitimate.

That leaves `--defaults` as the one deliberately non-failing channel: it is provenance only, never parsed, so nothing is inferred from its absence and it cannot make any determination fail open. Its entries record `readable` so a mis-wired path is still visible. This is a decision, not an oversight, and it is **not** promoted to an enforced assertion: doing so would make the gate depend on a file it deliberately does not trust, which is the opposite of the reframe.

### Absent flag vs empty value

One more shape of the same fail-open, closed in the same family: an **explicitly supplied empty value** is a wiring bug, not a request for nothing. `--report ""` was falsy, so no report was requested, none was written, and the checker printed `RK-RELCFG-OK` and exited 0 — reachable in CI simply by deleting or reordering the step that defines the path variable, since `bash -e` without `-u` leaves it empty. Empty values for `--config`, `--report`, `--log`, `--log-must-contain` and `--defaults` are now `RK-RELCFG-USAGE` (exit 64), as is `--log-must-contain` with no non-empty `--log` (which could only pass vacuously). Omitting a flag entirely remains legitimate and means "not requested" — that is the configure-time gate's case for `--log`. The host asserter applies the same rule to `--report`, `--config` and `--expect-log-marker`.

### Token precedence

When several conditions hold at once, **every** applicable token is printed and recorded in the report; only the exit code is single-valued, resolved as:

```
NOCONFIG (3)  >  NOREPORT (6)  >  NOLOG (5)  >  UNDEFINED (4)  >  VIOLATION (2)
```

The first three mean *no trustworthy determination was made, or none could be recorded*, and must outrank a mere policy violation — reporting "the optimization mode is wrong" when the real problem is "the config could not be parsed" would send the reader to the wrong place. Nothing is hidden by the precedence: a config that is both undefined and violating exits 4 while its violation rows remain visible in the report's `invariants`, and fixtures assert exactly that for every ordering.

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

So the checker **consumes** that line (`--log`) and never re-derives it. Three consequences worth stating:

* **The value is never captured.** The regex stops before the assigned value, because `sdkconfig.defaults` historically carried a credential and a gate must not become an exfiltration path. A fixture asserts the value never appears in output — including on the new `RK-RELCFG-NOLOG` paths, where only the path, a byte count and marker booleans are ever reported, never log content.
* **This layer is enforced in CI, not at configure time.** `kconfig.cmake` does not capture kconfgen's stdout, so the configure-time run's warnings are not available to the checker without re-invoking kconfgen. Rather than re-run it with reconstructed arguments, CI tees the build log and scans it. Locally, an undefined default warns (kconfgen's own output) but does not fail. That is an honest ceiling, not an oversight.
* **Delegation must not become abdication.** Consuming someone else's verdict introduces a failure mode reimplementation does not have: the verdict can simply fail to arrive. So requesting a log via `--log` makes its existence, non-emptiness and identity part of the contract — absent, unreadable, empty, or missing the `RK-RELCFG-VERDICT:` marker all produce `RK-RELCFG-NOLOG` (exit 5) and a `verdict:"fail"` report. This closed a real fail-open hole: the same invocation with a missing log previously exited 0 with `RK-RELCFG-OK`, so a renamed or dropped `tee` would have silently disabled one of #202's own acceptance criteria forever. Fixtures now cover missing, empty, whitespace-only and wrong-log cases, and the host asserter can require the report to *prove* a log was read (`--require-logs-read`).

### Removed lines

Confirmed by kconfgen **in the CI container** (measurement logs, all three builds): exactly four distinct undefined symbols, across five lines, all now removed —

| Old line | Symbol | Note |
|---|---|---|
| 1 | `CONFIG_WIFI_SSID` | never referenced by any source file |
| 2 | `CONFIG_WIFI_PASSWORD` | never referenced; had no effect on any build |
| 3 | `CONFIG_EXAMPLE_IPV6` | leftover from an IDF example |
| 33 | `CONFIG_LWIP_NETIF_HOSTNAME` | not an IDF symbol; hostname comes from `CONFIG_LWIP_LOCAL_HOSTNAME` |
| 85 | `CONFIG_LWIP_NETIF_HOSTNAME` | duplicate of line 33 |

**Retained deliberately:** the four brownout rename aliases (old lines 41–44), as required by the accepted phase-1 adjustment ("retain documented brownout rename aliases unless separately justified"). The rationale needs stating precisely, because an earlier draft of this record got it wrong:

* **The aliases do not carry the tuning.** The canonical `CONFIG_ESP_BROWNOUT_DET_LVL_SEL_4=y` and `CONFIG_ESP_BROWNOUT_DET_LVL=4` lines immediately above them carry the effective level-4 / 2.50 V configuration. The four alias lines resolve to those same two values through `esp_system/sdkconfig.rename` and `sdkconfig.rename.esp32s3`, so as *effective configuration* they are redundant. It is not true that deleting them would lose the tuning.
* **They are retained as transition/history compatibility inputs**, deliberately: they let this defaults file be applied to older trees and older branches (v4 lineage) where the pre-rename symbol names were the real ones, and they document, in-file, which names the tuning has travelled under. Deleting them is a separate, justifiable change — explicitly **out of scope here** and not made.
* **Their present behaviour is tested, not assumed.** `tools/fixtures/kconfgen_rename.log` carries the actual `was replaced with` notices these lines produce in the CI container, and a fixture asserts the checker exits 0 on them. Renames are not unknown symbols.
* **Their eventual promotion to `unknown kconfig symbol` is a deliberate, pre-explained loud signal, not a mystery.** When IDF eventually drops those rename entries, the log gate turns `build-idf` red naming the alias. That is the intended drift alarm: it tells us the compatibility window has closed, at which point the correct response is to delete the four alias lines (the canonical lines already carry the tuning, so the effective configuration does not change) and record that the window closed. This paragraph exists so that whoever sees that red build finds the answer here instead of guessing.

Note on line 2: it is removed because kconfgen proves it is undefined and inert, **not** as credential remediation. The value remains in git history, and history/credential remediation stays out of scope for #202 (private operational track). `idf_app/sdkconfig.override` was not read, modified, or staged.

## Mechanism details worth recording

### `SDKCONFIG_DEFAULTS` precedence — corrected

In `tools/cmake/project.cmake`, `_sdkconfig_defaults` is first seeded from `$ENV{SDKCONFIG_DEFAULTS}` and then, a few lines later, overwritten from the `SDKCONFIG_DEFAULTS` **cache variable** when one is set. So `-DSDKCONFIG_DEFAULTS` **wins over the environment**. (Stated by symbol rather than by line number, per the convention above; locate with `grep -n SDKCONFIG_DEFAULTS $IDF_PATH/tools/cmake/project.cmake`.) This matters twice: it is why the measurement's isolation against `scripts/install.sh`'s exported `sdkconfig.defaults;sdkconfig.local` was real rather than redundant, and it is one of the override paths that makes the defaults file untrustworthy as evidence.

### Why `fail_at_build_time()` and not `FATAL_ERROR`

`FATAL_ERROR` at configure time wedges `idf.py menuconfig`, which is one of the two documented recovery paths — the gate would block the tool you need to fix what it is complaining about. `fail_at_build_time()` instead fails `idf.py build` while leaving `menuconfig` (a non-`ALL` custom target) and `reconfigure` working, and it deletes its own stamp so the next invocation re-evaluates. Both recovery paths — fix it in `menuconfig`, or `rm sdkconfig && idf.py build` — are reachable **without** touching the escape hatch, which is what stops the opt-out from becoming the path of least resistance.

Two hardening requirements at the call site, both verified as real and both implemented:

* `fail_at_build_time(target, message_line0)` takes `message_line0` as a **required positional**, so an empty capture would become a configure-time CMake argument error — the exact hard failure the design avoids. The CMake wiring guarantees a non-empty first line.
* the helper does `foreach(line ${ARGN})`, which **splits on `;`**. The checker strips `;` from its output and the CMake wiring replaces any remaining `;` with `,`.

### Why `command:`-forcing over `extra_docker_args`

`CI` does not cross into the container, so enforcement cannot be inherited from the environment. Putting `-DRK_ENFORCE_RELEASE_CONFIG=ON` on the `idf.py` command line via the action's `command:` input makes the forcing **visible in the workflow diff** — an `-e` in `extra_docker_args` is both easier to miss in review and easier to drop silently.

### Enforcement ceilings — stated plainly

"CI cannot opt out" is true only with the host assertion, and even then it has edges:

1. `fail_at_build_time()` creates an `ALL` target, so the gate fires for **anything that builds `all`** — which includes both `idf.py build` and `idf.py flash`, since the flash action carries `all` in its dependencies. The bypass is narrower than an earlier draft of this record claimed: specifically **`idf.py app` and `idf.py app-flash`**, which build the app target directly. So the dominant local paths *are* covered, and a developer has to reach for a component-specific target to produce a `roon_knob.bin` with the gate never running. Local coverage is broad but not absolute.
2. The host assertion catches a flipped flag, a deleted checker, and a removed CMake call. It does **not** catch **deletion of the assertion step itself**, and nothing in-repo can. Closing that requires branch protection with required checks — out of repo, and not touched by #202.
3. `espressif/idf:release-v5.4` is a **mutable tag**. The measurement table above is attributable to `v5.4.4-1000-g8543b57cf15` / GCC 14.2.0 because those were recorded, but a future run of the same workflow may resolve to a different commit. Recording is not pinning; SDK pinning is #183. An invariant failure after the tag moves is drift detection working as intended — see "Why inherited defaults are asserted but not declared" above for the required response. If the numbers are ever re-derived, re-record the provenance rather than assuming this table still applies.
4. `RK_ENFORCE_RELEASE_CONFIG=OFF` is a CMake **cache** variable: once set in a build tree it persists for every subsequent build in that tree, with no further mention on the command line. The multi-line `*** RELEASE CONFIG INVARIANTS NOT ENFORCED ***` banner is re-emitted on every configure precisely so that state stays visible rather than silently inherited; if you are ever unsure whether a local artifact was gated, grep the build log for that banner.
5. The undefined-symbol layer is enforced **in CI, not at configure time**, because `kconfig.cmake` does not capture kconfgen's stdout for the checker to read. Locally an undefined default warns in kconfgen's own output but does not fail the build. This ceiling was previously worse than stated: a requested log that was absent, empty or unreadable used to be treated as "nothing found" and exit 0, which made the CI half fail *open*. That is now `RK-RELCFG-NOLOG` (exit 5), and CI additionally requires the log to contain `RK-RELCFG-VERDICT:` so a renamed or dropped `tee` cannot pass vacuously.

### Two rules for anything added to `build-idf` later

Both were learned the expensive way and are cheap to honour:

**Host steps may only READ under `idf_app/build/`.** The ESP-IDF container runs as root with no `--user` and the action passes no `-u`, so every path the container creates on the bind mount — including `build/config/` — is root-owned, while host `run:` steps execute as `runner`. An earlier revision of this work pointed the host log-scan `--report` at `idf_app/build/config/`, which no host step can write to. Anything a host step must write belongs in `$RUNNER_TEMP`; the path is defined once into `$GITHUB_ENV` so the writer and the reader cannot drift apart. Note what made this dangerous rather than merely broken: the checker swallowed the write failure and exited 0, so the *following* step failed with "no report … (checker did not run, or CMake call removed)" — a permission problem wearing a deleted-gate costume, whose cheapest-looking fix is deleting the assertion. That is why `RK-RELCFG-NOREPORT` exists.

**An auditor must not take its expectations from the artifact it audits.** `--require-logs-read` originally checked the log-identity marker against the report's own `logs_required_markers`. If a workflow edit drops `--log-must-contain`, that list is empty, the check iterates zero times, and the assertion passes while proving nothing. CI therefore supplies `--expect-log-marker 'RK-RELCFG-VERDICT:'` from the caller side, checked against what the report says it *observed*. Fixtures pin the gap shut, including a report that is internally self-consistent about having read the wrong log.

### `ESPTOOLPY_FLASHSIZE` = 16MB vs the 8MB merge — deliberately unresolved

`sdkconfig.defaults` declares `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"` while `.github/workflows/docker.yml`'s `esptool merge-bin` step passes `--flash-size 8MB`. That disagreement is real. #202 asserts the config value **only at what the committed defaults already declare**, touches no image header, and takes **no position** on the correct direction. Resolving it belongs to **#203** (with #193 for hardware identity).

It was suggested that the invariant should therefore be downgraded to a recorded-only provenance row, on the grounds that the gate should not certify a value the project may change. **Declined, deliberately.** #202's whole reframe is that the *effective* configuration must be pinned to what the project currently declares, so that it cannot drift silently; a value being scheduled for review is not a reason to stop noticing when it changes by accident. Recording-only would mean a stray `sdkconfig` that flipped the flash size to 4MB — which does change partition-table validity — would pass the gate. What is true, and worth stating so the next maintainer is not surprised, is that a #203 direction change is a **coherent three-place edit**: the expected value in `check_release_config.py`, `tools/fixtures/wrong_flashsize.json`, and the line above. That is the intended cost of pinning an effective value, and #203 changing all three together is the correct process, not a design smell.

### `sdkconfig.defaults.ble`

Invariants are declared for the default profile only. `sdkconfig.defaults.ble` is a manual, non-CI profile that flips `BT_ENABLED` / `ROON_KNOB_BLE_HID_ENABLED` and touches none of the asserted symbols. The checker's explicit `--config` path is the seam a future profile would use; **no profile mechanism is built here** (that is #200).

## Negative proof

| Layer | What only it can prove | Cost | Gates shipping? |
|---|---|---|---|
| `tools/fixtures/` + `tools/test_check_release_config.sh` (CI job `release-config-fixtures`) | the checker's logic: exact exit code and exact token per case, positive and negative, including that rename aliases pass, that a requested-but-unreadable log fails, that empty flag values are usage errors, and that assigned values are never echoed | host-only, seconds | **yes** — in `release` *and* `deploy-pr-preview` `needs:` |
| assert-the-assertion cases in the same runner | that the host gate has teeth: it rejects `enforced:false`, a digest belonging to another build, a missing report, a failing verdict, and a report proving no log was read | host-only, folded in rather than a separate job | **yes** — same job |
| `tools/cmake_gate_harness.cmake` + `tools/test_release_config_cmake.sh` (same job) | the **gate's** own decision paths under `cmake -P` with IDF's two commands stubbed: ON fails / OFF continues, `NOCHECKER`, empty output, `;`→`,`, `NOREPORT`, an unlaunchable interpreter, and a missing `fail_at_build_time` | host-only, seconds; needs `cmake` and `python3` only | **yes** — same job |
| the liveness canary in `build-stale-config` | that kconfgen still *emits* the diagnostic the delegated undefined-symbol determination reads — the one thing no recorded fixture can prove | zero extra container cost | **yes** — in `release` `needs:` |
| CI job `build-stale-config` | the wiring, **and that `fail_at_build_time()` is load-bearing**: a faithful stale tree fails with enforcement ON and builds successfully with enforcement OFF | two container builds (one of them incremental) | **yes** — in `release` `needs:` |

These jobs **require** evidence rather than merely producing it. `release` declares `needs: [build-idf, release-config-fixtures, build-stale-config]`, so a red checker-logic job or a red wiring job stops a `v*` tag from publishing firmware; `deploy-pr-preview` additionally needs the fast fixture job, so a hardware-flashable preview cannot come from a tree whose checker is broken. Neither prerequisite carries an `if:` event guard, deliberately: a *skipped* dependency skips the dependent job as well, so an event-guarded prerequisite would silently un-gate exactly the tag builds it was meant to protect. The price is that `build-stale-config` runs on every push, not only on pull requests — one container build of runner time, accepted in exchange for a graph whose safety does not depend on reading GitHub's skip semantics correctly.

### `build-stale-config` is a controlled ON/OFF pair, not a single red build

The first version of this job seeded a **three-line** `sdkconfig`. Because a stale `sdkconfig` overrides the defaults, that also dropped PSRAM, the custom partition table and the flash size — so the build could not link for reasons having nothing to do with the gate. Worse, all three of its assertions were satisfiable without `fail_at_build_time()` ever mattering: the violation token is printed at configure time by `message(STATUS)` **even when enforcement is OFF**, and the report is written unconditionally by design. The job proved the checker *noticed*. It did not prove the gate *blocked*, which is what #202 AC 6 asks for — and `fail_at_build_time()`, the single most load-bearing line in the change, was exercised by no test at all.

It is now a genuine control:

1. **Seed a faithful stale tree.** `idf_app/sdkconfig` is a full copy of `sdkconfig.defaults` with *only* the optimization selection regressed to `CONFIG_COMPILER_OPTIMIZATION_DEBUG=y` (plus the three `is not set` lines). A `diff` of both files with the optimization lines stripped must be empty, asserted in the job, so every other setting is provably identical and cannot be the cause of a failure.
2. **Run 1, enforcement ON — must fail.** Requires step outcome `failure`, the exact token `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG`, the `RK-RELCFG-ENFORCED` banner, and a report with `enforced: true` / `verdict: "fail"`. That report and the resolved `sdkconfig.json` are copied to `$RUNNER_TEMP` before run 2 overwrites them.
3. **Run 2, the positive control — identical tree, enforcement OFF, must SUCCEED.** No `continue-on-error`: requires the `*** RELEASE CONFIG INVARIANTS NOT ENFORCED ***` banner, a real `roon_knob.bin`, and a report with `enforced: false` / `verdict: "fail"`. If this run fails, something other than the gate was stopping the build and the negative proof above would have been worthless.
4. **Prove it was a controlled pair.** The two reports must carry the **same `config_digest`** and the same `fail` verdict, differing only in `enforced`. Same tree, same resolved configuration, same violation, opposite outcomes — which makes `fail_at_build_time()` the sole difference between a blocked build and a shipped one. Demonstrated, not assumed.

Two containers rather than one, so each outcome is separately attributable in the log. Neither run calls `set-target`, which would rename the seeded `sdkconfig` to `sdkconfig.old` and destroy the condition under test.

**Timeouts are initial ceilings, not measurements.** `build-idf` carries `timeout-minutes: 30` and `build-stale-config` `60`. The only wall-clock datum available is the measurement run (Actions `30498910795`), which compiled ~1751 ninja edges per mode in roughly three minutes on this runner class; the rest is margin for a cold image pull, and the two container runs in `build-stale-config` are serialised. Both numbers exist so that a hung build fails in minutes rather than at GitHub's six-hour default — they are not claims about how long these jobs take. **Record the actual wall time of the first real run and revisit both**; if `build-idf` lands near three minutes as expected, 30 is generous and can come down.

**Cost, stated accurately.** An earlier revision of this record called run 2 "incremental." It is not: `fail_at_build_time()`'s target has no dependencies, so ninja schedules it immediately and stops within seconds of the ON run starting — almost nothing is compiled, so there are almost no objects for run 2 to reuse. Run 2 is therefore effectively a **full** build, and this job costs roughly **two** full container builds. With `build-idf`, and with `build-stale-config` deliberately carrying no `if:` guard, every push, PR and tag pays about **three** full container builds. That is the real price of proving the gate blocks rather than merely notices; it is worth stating plainly so that a future cost-cutting pass makes an informed choice rather than discovering the bill.

### The one delegated determination gets a liveness canary

Eleven invariants are computed here. The twelfth — "this assignment names a symbol that does not exist" — is kconfgen's, consumed by regex from the build log. That asymmetry has a failure mode nothing else in this design has: `esp-idf-kconfig` is constrained only to `<3.0.0`, so a future release could reword the diagnostic and the checker would return "nothing found" indefinitely, silently. Fixtures cannot detect it, because a fixture is a recording of the old wording. Worse, that same silence would disarm the brownout-alias drift alarm promised above, whose whole premise is that the aliases eventually become *unknown* symbols and say so loudly.

So `build-stale-config` arms a canary against the live toolchain, at zero extra container cost:

* A uniquely named bogus assignment, `CONFIG_RK_CANARY_UNDEFINED_SYMBOL`, is appended to the CI checkout's `sdkconfig.defaults` — **test-only, never committed**, with a tripwire in the host fixture suite that fails if it ever appears in the committed file.
* It is appended **after** the seed/diff assertion (so byte-identity is unaffected) and **before** run 1 (so the #149 guard sees the same defaults hash on both runs; appending between them would trip its `FATAL_ERROR` in run 2 and break the control for the wrong reason).
* It goes into `sdkconfig.defaults`, never `sdkconfig`. An undefined symbol cannot reach `sdkconfig.json`, so both runs still resolve an identical effective config and the digest-equality control is preserved. kconfgen loads defaults *before* the existing config — "always load defaults first" is its own comment — so the warning is emitted even though the seeded `sdkconfig` already exists.
* After run 1, the host checker is run against the real ON-run log and requires **exactly** exit 4 with `RK-RELCFG-UNDEFINED: CONFIG_RK_CANARY_UNDEFINED_SYMBOL`. Exit 2 would mean the wording moved and the determination has gone quiet.
* The canary's *value* is a sentinel, and the assertion requires it never to appear in the checker's output — so the no-echo discipline is proven against real kconfgen output rather than against a fixture.

Simulated both ways before landing: with the current wording the assertion passes; with the warning reworded it fails with exit 1 and names the cause.

A failure with **no token** — container hiccup, checkout problem, unrelated configure error — still turns the job red, and correctly so: the token is what tells you the gate is what fired.

Exit codes are contract, asserted by fixtures: `0` OK, `2` violation, `3` no/malformed config, `4` undefined, `5` requested log absent/unreadable/empty/missing its marker, `6` requested report unwritable, `64` usage error (distinct from every verdict). Precedence is documented above.

The unwritable-report fixtures fail for **structural** reasons — the report's parent path component is an existing file, or the destination is an existing directory — rather than by `chmod`. Permission-based fixtures are not deterministic: they silently pass as writable when the suite runs as root, which is exactly the environment where a fail-open would matter least to detect and most to have.

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

* A release build that resolves to a debug or unsafe configuration fails from this commit onward, at configure time, naming the symbol. **First container-CI evidence is still outstanding** — see Status.
* CI's enforcement is designed to be provable from an artifact rather than assumed from a workflow line, and the jobs that prove it now **gate** publishing rather than merely reporting. Whether it holds in practice is a claim this record cannot yet make.
* The optimization mode is a recorded measurement, so the next maintainer does not have to guess whether it was reasoned or copied — but it is a *static* measurement; see "The limit of this measurement".
* `roon_knob.bin` shrinks from 1 761 952 B to 1 613 984 B (67.21 % → 61.57 % of the app slot) and static DIRAM drops 10 672 B. This is a **behavioural change** — `-Og` → `-Os` — and CI cannot validate it. It interacts with the brownout tuning above.
* Hardware validation is release-blocking but **not** merge-blocking: #202 merges on contract/CI evidence; #203's PR build (containing both #202 and #203) is the single combined hardware-test candidate; the release-blocking checklist lives on #189 and blocks **tagging**, not merging.
* New CI surface: enforcement forcing plus three host assertions in `build-idf`, one host fixture job, and one integration build that now runs on every push. The known adoption risk is that a red-for-infrastructure-reasons job gets `continue-on-error` or is quietly dropped during #203's workflow edit. Three things push against that: the fixtures job is seconds and host-only, the ADR names the required response to a drift-induced red build (remeasure and review, never allowlist), and both proof jobs are now in `release`'s `needs:` so dropping them is a visible change to the shipping path rather than a quiet one.

## Evidence that outlives the run

The gate is only useful later if its verdict is recoverable later. Two cheap, firmware-free additions:

* `idf_app/build/config/rk_release_config.json` rides along in the existing `esp32s3-firmware` artifact, next to the binary it describes. Be precise about what that preserves: the **verdict, the enforced state, the sha256 of the config that was gated, and one evidence row per invariant** — *not* the gated configuration itself, which cannot be reconstructed from the report. The resolved `sdkconfig.json` is deliberately **not** uploaded: artifacts on a public repository are world-downloadable, and that file is exactly where a future `sdkconfig.local`-style credential would surface, which would undo the checker's own no-echo discipline. So the report is digest-*bearing* but not, in the artifact, digest-*bound* to a published config file; the binding is same-job provenance plus the per-file assertion below, and the `release` job re-asserts the report itself. Recovering the full configuration of a past release remains a #203 concern.
* **Per-file existence is asserted explicitly**, by a host `test -f` over all three artifact inputs (app binary, merged binary, report) immediately before the upload. `if-no-files-found: error` is retained as defence in depth but is **not** a per-file guarantee: `actions/upload-artifact` evaluates it once against the *combined* search result, so with three patterns it fires only when all of them match nothing — the report could be absent and the upload would still be green because the binaries matched. An earlier revision of this record claimed otherwise; the claim was wrong, and a decision record asserting a protection that does not exist is worse than a disclosed gap.
* After the assertions pass — never before, so a summary cannot announce a verdict that was not also enforced — `build-idf` writes the **resolved optimization mode**, verdict, enforced state, config digest, tokens, and the run identity (`repository`, run id, attempt, commit) to `$GITHUB_STEP_SUMMARY`. The mode is read from the report's `invariants` rows, not from the defaults file, because the invariant deliberately accepts SIZE *or* PERF and so "verdict: pass" does not by itself say which one shipped. That step carries `if: always()` so failing runs — where the evidence matters most — still publish; it cannot mask an earlier failure, because a failed step has already failed the job and `always()` only adds a step. It tolerates a missing report and says so, since a build that died before configure never wrote one; the requirement that a *successful* build produce one is carried by the assertion steps, which do not use `always()`.
* **The `release` job re-asserts the evidence it is about to publish**, after `download-artifact`: the report must be present in the artifact with `enforced: true` and `verdict: pass`, and the release tag, resolved mode, verdict and config digest are recorded in that job's run summary before any asset is uploaded. `build-idf` being a `needs:` prerequisite proves a green job ran; this proves the *thing being published* carries a passing gate report. The job already checks the repo out (so the asserter is present) and `python3` is preinstalled on `ubuntu-latest`.

Together these make #189's release-blocking checklist satisfiable from CI output rather than from recollection. The log-scan report stays host-temporary in `$RUNNER_TEMP` deliberately: it is a transient proof that a log was read, not a description of the shipped configuration, and persisting it would invite reading the wrong one of the two reports.

**No firmware-reported digest exists, and #202 adds none.** #189's checklist wording asks for a firmware-reported release-config digest reconciled against the CI report; nothing in `idf_app/main` or `idf_app/components` embeds or reports one, and adding it would be firmware behaviour, which #202 excludes. So that half of the checklist item is **knowingly deferred to #203**, not silently waived — see the handoff below. What #202 does provide is the CI-side half: a persisted report and a run summary that a human can reconcile against the flashed build.

## Handoff to #203

Carry these forward when #203 opens; they are consequences of #202, not #202's own scope:

**Static / build-time (the half CI can check):**

1. Reconcile `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"` against `esptool merge-bin --flash-size 8MB`, and decide the direction (with #193 for hardware identity).
2. Image geometry and partition-fits-flash checks; size-headroom gate against the `0x280000` app slot — SIZE currently sits at 61.57 %.
3. `PROJECT_VER` binary inspection and the build-evidence artifact (`$GITHUB_STEP_SUMMARY` reporting), both deliberately excluded here.
4. Re-measure DEBUG/SIZE/PERF if the SDK moves, and **re-record provenance** rather than reusing this table.

**Hardware (the half CI cannot check) — the combined #202+#203 PR build is the single test candidate:**

5. **Encoder input latency** at `-Os`, including fast continuous rotation.
6. **LVGL redraw** smoothness — artwork transitions, screen changes, dropped frames or tearing that `-Og` did not show.
7. **Battery brownout at `-Os`** against the level-4 / 2.50 V tuning, on battery, through Wi-Fi association inrush.
8. **Boot and OTA from a prior `-Og` release**, confirming the mode change does not break the update path.
9. Board revision recorded, plus the enforcement banner and a `sha256sum` reconcilable with the CI artifact.
10. **A firmware-reported release-config digest**, if #189's checklist wording is to be met literally. #202 adds none — that is firmware behaviour and out of its scope — so #203 either implements it or the checklist item is amended to accept the CI-side evidence (persisted report + run summary) that #202 does provide.

## Acceptance bookkeeping

#202 has **ten** acceptance criteria; earlier revisions of this record miscounted them as eleven, so the two below were cited one number too high.

* **AC 10 (update #181 to remove any cleanup item completed here): satisfied.** The `## Stale kconfig symbols in sdkconfig.defaults` section, naming all four symbols this work removed, was deleted from #181 by a content edit recorded at `2026-07-30T00:04:06Z` and confirmed through the issue's `userContentEdits` history. #181's remaining scope — the `bridge_client.c` dead-code warnings and the ESP-IDF 6.0 bump — is untouched and the issue stays open, which is correct. (A reading that #181 "never contained anything #202 completed" is contradicted by that edit history; the section existed and was removed.)
* Ticking #202's own acceptance checkboxes and #189's execution-split box is ship-phase bookkeeping, deliberately left for when the amended commit reaches PR #204. PR #204's title still describes the measurement harness this work deleted and should be retitled at the same time.
* **AC 9 (record the decision) is satisfied by this file**, and the operator-facing half now lives in [`docs/dev/KCONFIG.md`](../../dev/KCONFIG.md#release-config-gate-202): the tokens, the two recovery paths, and the local-only `-DRK_ENFORCE_RELEASE_CONFIG=OFF` hatch with its cache-persistence caveat. `CLAUDE.md` routes build/config questions there, so a developer whose local build fails with `RK-RELCFG-VIOLATION` finds the answer where they look first rather than only in a decision record.

If 5–8 regress, the remedy is the one-line SIZE→PERF switch in `sdkconfig.defaults`, which the gate still checks — not disabling the gate.

## References

* Checker: `idf_app/tools/check_release_config.py`
* Host assertion: `idf_app/tools/assert_release_report.py`
* Fixtures + runner: `idf_app/tools/fixtures/`, `idf_app/tools/test_check_release_config.sh`
* CMake wiring: `idf_app/cmake/rk_release_config.cmake`; #149 guard in `idf_app/CMakeLists.txt`
* CI: `.github/workflows/docker.yml` (`build-idf`, `release-config-fixtures`, `build-stale-config`)
* Measurement run: GitHub Actions `30498910795`, draft PR #204
