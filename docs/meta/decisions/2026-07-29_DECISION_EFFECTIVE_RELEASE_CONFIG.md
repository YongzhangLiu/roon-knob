# Decision: enforce the *effective* firmware release configuration

**Date:** 2026-07-29
**Issue:** [#202](https://github.com/muness/roon-knob/issues/202) (parent [#189](https://github.com/muness/roon-knob/issues/189), program [#201](https://github.com/muness/roon-knob/issues/201), epic [#196](https://github.com/muness/roon-knob/issues/196))
**Status:** Accepted; implemented and enforced from this commit. **Pending first container-CI evidence** — the gate, both host assertions, `release-config-fixtures` and `build-stale-config` have never executed in CI at the time of writing. Host-side proof is real (fixture suite green); the container half is designed-for, not observed. Backfill the run ID here once PR #204 carries this commit and all four surfaces are green.
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

What makes that acceptable rather than reckless is reversibility: the gate accepts SIZE **or** PERF, so switching is a one-line `sdkconfig.defaults` diff that the gate still checks — no gate, fixture, or ADR edit required.

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
| `ESP_DEBUG_STUBS_ENABLE` | false | debug-only on-target stubs | `esp_system/Kconfig` (its default tracks the debug optimization level, so choosing SIZE satisfies this as a side effect rather than by declaration) |
| `ESP_SYSTEM_PANIC_GDBSTUB` | false | a field device must reboot, not wait for gdb | `esp_system/Kconfig`, `choice ESP_SYSTEM_PANIC` (non-default member) |
| `FREERTOS_USE_TRACE_FACILITY` | false | debug-only scheduler bookkeeping | `freertos/Kconfig` (`default n`; selected only by `FREERTOS_GENERATE_RUN_TIME_STATS`, itself `default n`) |
| `ESPTOOLPY_FLASHSIZE` | `"16MB"` | must match what the committed defaults declare | `esptool_py/Kconfig.projbuild` (string, defaulted from the `ESPTOOLPY_FLASHSIZE_*` choice) |

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

That leaves `--defaults` as the one deliberately non-failing channel: it is provenance only, never parsed, so nothing is inferred from its absence and it cannot make any determination fail open. Its entries record `readable` so a mis-wired path is still visible. This is a decision, not an oversight.

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

### `sdkconfig.defaults.ble`

Invariants are declared for the default profile only. `sdkconfig.defaults.ble` is a manual, non-CI profile that flips `BT_ENABLED` / `ROON_KNOB_BLE_HID_ENABLED` and touches none of the asserted symbols. The checker's explicit `--config` path is the seam a future profile would use; **no profile mechanism is built here** (that is #200).

## Negative proof

| Layer | What only it can prove | Cost | Gates shipping? |
|---|---|---|---|
| `tools/fixtures/` + `tools/test_check_release_config.sh` (CI job `release-config-fixtures`) | the checker's logic: exact exit code and exact token per case, positive and negative, including that rename aliases pass, that a requested-but-unreadable log fails, and that assigned values are never echoed | host-only, seconds | **yes** — in `release` *and* `deploy-pr-preview` `needs:` |
| assert-the-assertion cases in the same runner | that the host gate has teeth: it rejects `enforced:false`, a digest belonging to another build, a missing report, a failing verdict, and a report proving no log was read | host-only, folded in rather than a separate job | **yes** — same job |
| CI job `build-stale-config` | the wiring: a stale `sdkconfig` that ignores the committed defaults is caught at configure time, for the stated reason | one container build | **yes** — in `release` `needs:` |

These jobs **require** evidence rather than merely producing it. `release` declares `needs: [build-idf, release-config-fixtures, build-stale-config]`, so a red checker-logic job or a red wiring job stops a `v*` tag from publishing firmware; `deploy-pr-preview` additionally needs the fast fixture job, so a hardware-flashable preview cannot come from a tree whose checker is broken. Neither prerequisite carries an `if:` event guard, deliberately: a *skipped* dependency skips the dependent job as well, so an event-guarded prerequisite would silently un-gate exactly the tag builds it was meant to protect. The price is that `build-stale-config` runs on every push, not only on pull requests — one container build of runner time, accepted in exchange for a graph whose safety does not depend on reading GitHub's skip semantics correctly.

`build-stale-config` requires **all three** of: step outcome `failure`, the exact token `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG` in the log, and a report with `verdict:"fail"`. **The discriminator is the token, not the step outcome.** An earlier draft of this record claimed an unrelated compile break "yields the first but not the other two" — that is wrong, and the correction matters: the gate fires at *configure* time, before any compilation, so in this deliberately-violating tree the report and the token are already produced and a later compile break changes neither. What the three-way requirement actually buys is that a failure with **no token** — a container hiccup, a checkout problem, a configure error unrelated to the gate — cannot be mistaken for the gate firing. The job goes red either way; the token is what tells you *why*, which is the whole point of asserting the reason rather than the failure.

It never calls `set-target`, which would rename the seeded `sdkconfig` to `sdkconfig.old` and destroy the condition under test.

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

* `idf_app/build/config/rk_release_config.json` now rides along in the existing `esp32s3-firmware` artifact, next to the binary it describes, with `if-no-files-found: error` so a missing report (or a missing binary) cannot pass as a green upload — the same requested-artifact fail-open class as `RK-RELCFG-NOREPORT`, closed in the same pass rather than one channel at a time.
* After the assertions pass — never before, so a summary cannot announce a verdict that was not also enforced — `build-idf` writes verdict, enforced state, config digest, tokens, and the run identity (`repository`, run id, attempt, commit) to `$GITHUB_STEP_SUMMARY`.

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

* **AC 11 (update #181 to remove any cleanup item completed here): satisfied.** The `## Stale kconfig symbols in sdkconfig.defaults` section, naming all four symbols this work removed, was deleted from #181 by a content edit recorded at `2026-07-30T00:04:06Z` and confirmed through the issue's `userContentEdits` history. #181's remaining scope — the `bridge_client.c` dead-code warnings and the ESP-IDF 6.0 bump — is untouched and the issue stays open, which is correct. (A reading that #181 "never contained anything #202 completed" is contradicted by that edit history; the section existed and was removed.)
* Ticking #202's own acceptance checkboxes and #189's execution-split box is ship-phase bookkeeping, deliberately left for when the amended commit reaches PR #204.

If 5–8 regress, the remedy is the one-line SIZE→PERF switch in `sdkconfig.defaults`, which the gate still checks — not disabling the gate.

## References

* Checker: `idf_app/tools/check_release_config.py`
* Host assertion: `idf_app/tools/assert_release_report.py`
* Fixtures + runner: `idf_app/tools/fixtures/`, `idf_app/tools/test_check_release_config.sh`
* CMake wiring: `idf_app/cmake/rk_release_config.cmake`; #149 guard in `idf_app/CMakeLists.txt`
* CI: `.github/workflows/docker.yml` (`build-idf`, `release-config-fixtures`, `build-stale-config`)
* Measurement run: GitHub Actions `30498910795`, draft PR #204
