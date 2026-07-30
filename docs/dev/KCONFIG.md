# Kconfig Options

This document covers the build-time configuration options available for the Roon Knob firmware.

## Overview

ESP-IDF uses Kconfig for compile-time configuration. Options are defined in `Kconfig.projbuild` and defaults are set in `sdkconfig.defaults`. After changing options, rebuild the firmware to apply them.

## Project-Specific Options

### Roon-Knob Defaults Menu

Options for development and testing. In production, these are typically left empty (WiFi is configured via captive portal, bridge via mDNS).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `CONFIG_RK_DEFAULT_SSID` | string | `""` | Pre-configured WiFi SSID |
| `CONFIG_RK_DEFAULT_PASS` | string | `""` | Pre-configured WiFi password |
| `CONFIG_RK_DEFAULT_BRIDGE_BASE` | string | `""` | Bridge URL fallback if mDNS fails |

**Usage:** Set these during development to skip the provisioning flow:

```bash
idf.py menuconfig
# Navigate to: Roon-Knob Defaults
# Set your home WiFi credentials
```

### Display Sleep Settings Menu

Controls display power management behavior.

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `CONFIG_RK_DISPLAY_DIM_TIMEOUT_SEC` | int | 30 | 5-300 | Seconds before dimming |
| `CONFIG_RK_DISPLAY_SLEEP_TIMEOUT_SEC` | int | 60 | 10-600 | Seconds before sleep |
| `CONFIG_RK_BACKLIGHT_NORMAL` | int | 100 | 0-255 | Normal brightness (~40%) |
| `CONFIG_RK_BACKLIGHT_DIM` | int | 25 | 0-255 | Dimmed brightness (~10%) |

**Timeline:**

```
User activity → [30s idle] → Dim → [30s more] → Sleep
                              ↑                    ↑
                        (60-30=30s)           (total 60s)
```

**Brightness scale:** 0-255 maps to PWM duty cycle. Perception is non-linear:
- 25 (~10%) is visible but very dim
- 100 (~40%) is comfortable for indoor use
- 255 (100%) is maximum, may be too bright

## ESP-IDF Options (sdkconfig.defaults)

### Flash Configuration

```
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_ESPTOOLPY_FLASHSIZE="16MB"
```

The ESP32-S3-Knob has 16MB flash. This enables the full partition layout including OTA slots.

**Known open disagreement:** the merged flash image CI builds for web flashing passes `esptool merge-bin --flash-size 8MB`, which does not match the 16MB declared here. The release config gate (see [Release Config Gate](#release-config-gate-202)) **pins** the resolved configuration at the `"16MB"` declared above — a build that resolves to any other flash size fails the gate — and **defers the correct direction** to [#203](https://github.com/muness/roon-knob/issues/203). It is not neutral about the value, only about which value is right for this device. The gate reads no image header, so a passing config verdict says nothing about image geometry.

So if #203 decides 8MB, that is an **edit and not merely a decision**, and it is a coherent multi-place one — reaching well past the two lines above, into the checker and its comment, the fixture corpus, the committed suite that pins the violation token, the `merge-bin` invocation that produces the 8MB image, both CI run-summary caveats, the manual flashing guide, this page and the decision record. Do not treat that sentence as the list. **Re-derive the surface with the command in the decision record's [`ESPTOOLPY_FLASHSIZE` section](../meta/decisions/2026-07-29_DECISION_EFFECTIVE_RELEASE_CONFIG.md#esptoolpy_flashsize--16mb-vs-the-8mb-merge--direction-deferred-value-pinned), whose reviewed output is canonical** — read the categories and the judgement there rather than trusting a second copy here, because a duplicated list is how an undercount survives, and three revisions of that list were short before authority moved to the command. One trap is worth carrying inline so nobody starts without it: **`tools/fixtures/wrong_flashsize.json`'s wrong value *is* `"8MB"`**, so flipping the expectation inverts that fixture instead of updating it — it must be re-pointed at a genuinely wrong value, not re-valued and not deleted. The suite goes loudly red on the flip, and the cheapest-looking repair (relaxing or dropping the case) silently removes negative coverage.

### PSRAM Configuration

```
CONFIG_SPIRAM=y
CONFIG_SPIRAM_MODE_OCT=y
CONFIG_SPIRAM_SPEED_80M=y
CONFIG_SPIRAM_BOOT_INIT=y
CONFIG_SPIRAM_USE_MALLOC=y
CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=16384
CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y
```

| Option | Purpose |
|--------|---------|
| `SPIRAM=y` | Enable 8MB PSRAM |
| `MODE_OCT` | Octal SPI mode (faster) |
| `SPEED_80M` | 80MHz clock |
| `USE_MALLOC` | Include PSRAM in heap |
| `ALWAYSINTERNAL=16384` | Allocations <16KB use internal RAM |
| `TRY_ALLOCATE_WIFI_LWIP` | Let WiFi/TCP use PSRAM |

PSRAM is used for large buffers like album artwork (360×360×2 = 259KB).

### Brownout Detection

```
CONFIG_ESP_BROWNOUT_DET=y
CONFIG_ESP_BROWNOUT_DET_LVL_SEL_4=y
CONFIG_ESP_BROWNOUT_DET_LVL=4
```

**Why Level 4 (2.50V)?**

The default Level 7 (2.80V) triggers false brownouts during WiFi transmission on battery power. WiFi causes ~500mA current spikes that momentarily drop voltage. Level 4 tolerates these transients.

| Level | Voltage | Use Case |
|-------|---------|----------|
| 7 | 2.80V | USB-powered only |
| 4 | 2.50V | Battery operation ✓ |
| 1 | 2.36V | Aggressive, risk of instability |

### LVGL Fonts

```
CONFIG_LV_FONT_MONTSERRAT_14=y
CONFIG_LV_FONT_MONTSERRAT_18=y
CONFIG_LV_FONT_MONTSERRAT_20=y
CONFIG_LV_FONT_MONTSERRAT_22=y
CONFIG_LV_FONT_MONTSERRAT_24=y
CONFIG_LV_FONT_MONTSERRAT_28=y
CONFIG_LV_FONT_MONTSERRAT_30=y
CONFIG_LV_FONT_MONTSERRAT_32=y
CONFIG_LV_FONT_MONTSERRAT_48=y
```

Enables various Montserrat font sizes for the UI. Each adds ~10-20KB to the binary. The 360×360 display uses larger fonts (20-48pt) for readability.

### HTTP Server

```
CONFIG_HTTPD_MAX_REQ_HDR_LEN=2048
```

Default 1024 bytes is insufficient for modern browsers that send many headers. 2048 bytes accommodates typical browser requests to the captive portal.

### Partition Table

```
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions.csv"
```

Uses custom partition layout for dual-OTA support. See [OTA_UPDATES.md](../usage/OTA_UPDATES.md) for partition details.

## Changing Options

**IMPORTANT:** The `sdkconfig` file (generated) takes precedence over `sdkconfig.defaults`. If you add new options to `sdkconfig.defaults`, you MUST delete sdkconfig to apply them:

```bash
# After editing sdkconfig.defaults:
rm sdkconfig
idf.py build
```

Simply running `idf.py reconfigure` or `idf.py fullclean` is NOT sufficient—the sdkconfig file must be deleted.

### Via menuconfig (Interactive)

```bash
cd idf_app
idf.py menuconfig
# Navigate menus, change values
# Save and exit
idf.py build
```

### Via sdkconfig.defaults (Persistent)

Edit `idf_app/sdkconfig.defaults` and rebuild:

```bash
# Add or modify options
echo "CONFIG_RK_DISPLAY_DIM_TIMEOUT_SEC=60" >> sdkconfig.defaults

# Clean and rebuild to apply
idf.py fullclean
idf.py build
```

### Via Command Line (Temporary)

```bash
idf.py -D CONFIG_RK_DEFAULT_SSID="MyWiFi" build
```

Note: Command-line overrides don't persist to `sdkconfig`.

## Option Precedence

1. **sdkconfig** (generated, highest priority)
2. **sdkconfig.defaults** (project defaults)
3. **Kconfig defaults** (lowest priority)

After `idf.py menuconfig`, changes are saved to `sdkconfig`. To reset to defaults:

```bash
rm sdkconfig
idf.py reconfigure
```

## Release Config Gate (#202)

Because `sdkconfig` outranks `sdkconfig.defaults` (see above), a stale `sdkconfig` can silently ship a debug build. A configure-time gate therefore validates IDF's **resolved** configuration — `build/config/sdkconfig.json`, not the defaults file — every time you configure.

The gate is `idf_app/cmake/rk_release_config.cmake`, the checker is `idf_app/tools/check_release_config.py`, and the full rationale is in [the decision record](../meta/decisions/2026-07-29_DECISION_EFFECTIVE_RELEASE_CONFIG.md).

### What it enforces

Release builds must be optimized (exactly one of `CONFIG_COMPILER_OPTIMIZATION_SIZE` / `_PERF`, never `_DEBUG` / `_NONE`), must keep PSRAM and the custom partition table, must keep assertions enabled, and must not enable debug-only facilities (gdbstub panic handler, debug stubs, heap poisoning/tracing, FreeRTOS trace).

The committed default is currently **SIZE**, chosen by measurement. The gate accepts either optimized mode on purpose: switching to `CONFIG_COMPILER_OPTIMIZATION_PERF=y` is a one-line change to `sdkconfig.defaults` and needs no change to the gate, its fixtures, the CI workflow, or the decision record.

### Reading the output

Every verdict is a stable `RK-RELCFG-*` token, so a failure always says *why*:

| Token | Exit | Meaning |
|---|---|---|
| `RK-RELCFG-OK` | 0 | all invariants hold |
| `RK-RELCFG-VIOLATION: <SYMBOL>` | 2 | the resolved config breaks that invariant |
| `RK-RELCFG-NOCONFIG` | 3 | `sdkconfig.json` missing or unparseable |
| `RK-RELCFG-UNDEFINED: <SYMBOL>` | 4 | an invariant symbol vanished, or kconfgen reported an assignment to an unknown symbol |
| `RK-RELCFG-NOLOG` | 5 | a log was requested but is absent/empty/not the gate's own |
| `RK-RELCFG-NOREPORT` | 6 | the JSON report could not be written |
| `RK-RELCFG-USAGE` | 64 | bad invocation (including a flag given an empty value) |
| `RK-RELCFG-NOHELPER` | — | a required ESP-IDF CMake command is missing (see below) |

`RK-RELCFG-NOHELPER` is the one token with **no checker exit code**, because the checker never runs: it comes from the CMake gate itself as a configure-time `FATAL_ERROR` when `idf_build_get_property` or `fail_at_build_time` is not defined. That means either the gate was included before `project()`, or this ESP-IDF version no longer provides the helper — and without `fail_at_build_time` the gate cannot fail closed, so it refuses to run rather than pass silently. Unlike a violation, this one does stop `menuconfig`, because it is an environment defect rather than a configuration verdict. The message names the missing command.

The gate also writes `build/config/rk_release_config.json` on every configure, enforced or not, and CI uploads it with the firmware.

### What a pass does *not* mean

`RK-RELCFG-OK` is a verdict about the **resolved Kconfig configuration**, not about the flash image. In particular the gate checks that the configuration declares `CONFIG_ESPTOOLPY_FLASHSIZE="16MB"` — matching the committed defaults — but it does not read or validate any image header. The merged image CI publishes for web flashing is currently built with `esptool merge-bin --flash-size 8MB`, so that disagreement is real and open pending [#203](https://github.com/muness/roon-knob/issues/203). Both CI run summaries state this caveat inline, so a green gate table is not mistaken for a validated image. Image geometry, partition-fits-flash and size-headroom checks are #203's scope, not this gate's.

### Normal recovery — no escape hatch needed

The gate defers failure to build time rather than aborting configure, precisely so that both recovery paths keep working:

```bash
# 1. Fix it interactively - menuconfig still opens from a violating tree
idf.py menuconfig

# 2. Or re-derive the config from the committed defaults (the usual fix)
rm sdkconfig
idf.py build
```

If the message is `RK-RELCFG-VIOLATION: COMPILER_OPTIMIZATION_DEBUG`, option 2 is almost certainly what you want: your `sdkconfig` predates the current defaults.

### If it fails on a symbol nobody touched

Several invariants pin values ESP-IDF supplies as its own defaults, over the mutable `release-v5.4` tag. If one of those flips upstream, the gate goes red naming a symbol no one in this repo changed. **That is drift detection working, not a broken gate**, and the response is a short procedure rather than an unblock:

1. **Remeasure and review** — find what the value is now and why it changed, reading the symbol's declaration at the IDF commit CI actually resolved.
2. **Decide whether the new upstream default is right for this device.** This is a product judgement and needs review.
3. Then either **amend the invariant** to the reviewed value, or **declare the value explicitly** in `sdkconfig.defaults` — recording *why* in both cases.

What you must **never** do: set `RK_ENFORCE_RELEASE_CONFIG=OFF` in CI, add `continue-on-error`, delete the gate or assertion step, or add a blanket allowlist. Each turns a one-time review into a permanent silent hole — a job that still looks green while enforcing nothing. The full rationale is in the decision record under *The permitted response to upstream drift*.

### Local-only escape hatch

```bash
idf.py -DRK_ENFORCE_RELEASE_CONFIG=OFF build
```

This suppresses only the **failure**. The checker still runs, the report is still written with `enforced: false`, and a multi-line `*** RELEASE CONFIG INVARIANTS NOT ENFORCED ***` banner is printed on every configure.

Two things to know before using it:

- **It is a CMake cache variable, so it persists** for every later build in that build directory, with no further mention on the command line. If you are unsure whether a local binary was gated, grep the build log for that banner, or `rm -rf build` to reset.
- **CI cannot use it, and cannot silently build unenforced.** The workflow passes `-DRK_ENFORCE_RELEASE_CONFIG=ON` explicitly and then asserts the report on the host, so a `build-idf` job cannot run with enforcement off, and an artifact built with enforcement off cannot be **published**. Both publishing consumers gate on the **same three** proof jobs — `release` and `deploy-pr-preview` each declare `needs: [build-idf, release-config-fixtures, build-stale-config]` — so any one of them red or skipped stops both a `v*` tag from publishing firmware and a PR preview from being flashed. (An earlier version of this page described `deploy-pr-preview` as needing only two of the three; that asymmetry has been closed.)
- **And CI does not block merging at all.** Branch protection on `master` currently defines no required status checks and no required approvals, so a red #202 job stops a release and a preview but never stops a merge. Making these jobs required checks is a repository-settings change that needs maintainer authorization; see the decision record's *Enforcement ceilings* section.

Prefer `rm sdkconfig` over the hatch. The hatch exists for the case where you deliberately want a debug-optimized local build (`CONFIG_COMPILER_OPTIMIZATION_DEBUG=y` for stepping through code), not as a way past an inconvenient message.

Note that `idf.py app` and `idf.py app-flash` build the app target directly and bypass the gate; `idf.py build` and `idf.py flash` do not.

## Development vs Production

### Development Build

```
# sdkconfig.defaults.dev (create this file)
CONFIG_RK_DEFAULT_SSID="MyHomeWiFi"
CONFIG_RK_DEFAULT_PASS="mypassword"
CONFIG_RK_DEFAULT_BRIDGE_BASE="http://192.168.1.100:8088"
CONFIG_LOG_DEFAULT_LEVEL_DEBUG=y
```

```bash
idf.py -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.dev" build
```

### Production Build

Use only `sdkconfig.defaults` with empty WiFi credentials. Users configure via captive portal.

## Adding New Options

### 1. Define in Kconfig.projbuild

```kconfig
menu "My Feature"

config MY_FEATURE_ENABLED
    bool "Enable my feature"
    default y
    help
        Enable or disable my feature.

config MY_FEATURE_TIMEOUT
    int "Timeout in seconds"
    default 10
    range 1 60
    depends on MY_FEATURE_ENABLED

endmenu
```

### 2. Use in Code

```c
#include "sdkconfig.h"

#ifdef CONFIG_MY_FEATURE_ENABLED
void my_feature_init(void) {
    int timeout = CONFIG_MY_FEATURE_TIMEOUT;
    // ...
}
#endif
```

### 3. Set Defaults

```bash
# Add to sdkconfig.defaults
CONFIG_MY_FEATURE_ENABLED=y
CONFIG_MY_FEATURE_TIMEOUT=10
```

## Reference Files

| File | Purpose |
|------|---------|
| `idf_app/main/Kconfig.projbuild` | Project-specific option definitions |
| `idf_app/sdkconfig.defaults` | Default values for all builds |
| `idf_app/sdkconfig` | Generated config (don't commit) |
