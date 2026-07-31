# BLE HID Remote Host

HiPhi controllers can pair with a separate Bluetooth Low Energy media remote.
The firmware acts as the BLE HID **host**: it scans for a remote that exposes
the HID over GATT Profile (HOGP), receives Consumer Control reports, and maps
supported keys into the shared playback controller.

This is not the older, unimplemented mode where the historical Roon Knob advertised itself as
a BLE keyboard/media controller. The two roles are opposites:

| Role | This firmware | Peer |
| --- | --- | --- |
| BLE HID host | HiPhi Frame or HiPhi Dial | Physical media remote |
| BLE HID device | Not implemented | Phone, computer, or TV |

ESP32-S3 supports Bluetooth LE but not Classic Bluetooth. This feature neither
uses nor claims Classic Bluetooth, A2DP, or AVRCP support.

## Supported input

The shared host maps these Consumer Control usages:

| Remote key | Controller action |
| --- | --- |
| Play/Pause | Toggle playback |
| Next Track | Next track |
| Previous Track | Previous track |
| Volume Up | Increase the selected zone's volume |
| Volume Down | Decrease the selected zone's volume |

Mute is ignored because the shared controller does not currently expose an
explicit mute command. Unknown report formats and usages are ignored safely.
HOGP remotes are not perfectly uniform, so support must be verified with the
specific remote.

## Target behavior

- **HiPhi Frame:** enabled by default to preserve its established behavior.
- **HiPhi Dial:** compiled into the normal ESP32-S3 firmware but disabled by
  default. Enable it from the connected device's settings page.
- Pairing, enablement, and the remembered remote are stored only in that
  device's local NVS. Nothing is copied or synchronized between Frame and
  Dial.

Both targets expose scan, pair, connection status, disable, and forget
operations through target-owned settings. Display code remains target-specific;
the shared Bluetooth component never calls e-ink or LVGL APIs.

## Lifecycle

The shared `rk_ble_hid_host` component owns NimBLE and `esp_hid` behind one
serialized command queue. Its public lifecycle is:

```
UNAVAILABLE -> DISABLED -> STARTING -> READY
                                      |-> SCANNING
                                      |-> CONNECTING -> CONNECTED
active state -> STOPPING -> DISABLED
```

Disable cancels outstanding work, closes and frees HID devices, deinitializes
the HID host, stops the NimBLE host task, waits for its exit acknowledgement,
and then deinitializes the NimBLE port. If bounded teardown cannot complete,
the service reports an error that requires reboot instead of pretending it is
safe to re-enable.

Startup NVS, NimBLE, HID, and host-sync failures are reported by name and retried
up to five times with bounded backoff. A successful sync clears the retry
budget. Exhausted startup retries remain in `ERROR`; teardown failures remain
reboot-required.

Forget is stronger than disconnect: it invalidates reconnect work, clears the
local remembered-device metadata, and deletes the NimBLE peer security record.

## Pairing

1. Connect the controller to Wi-Fi.
2. Open its settings page in a browser.
3. On Dial, enable **BLE Media Remote** if it is disabled.
4. Put the physical remote into pairing mode.
5. Start a scan and select the remote.
6. Confirm transport and volume keys operate the selected playback zone.

Pairing uses the BLE “Just Works” security model because these controllers and
typical media remotes have no shared display/PIN-entry path. The bond is kept
in NVS so the host can reconnect after restart.

## Build configuration

The shipping Frame and Dial ESP32-S3 artifacts enable the shared host
capability:

```text
CONFIG_RK_BLE_HID_HOST=y
CONFIG_BT_ENABLED=y
CONFIG_BT_NIMBLE_ENABLED=y
CONFIG_BT_NIMBLE_NVS_PERSIST=y
CONFIG_BT_NIMBLE_SM_SC=y
CONFIG_BT_NIMBLE_HID_SERVICE=y
```

Targets that intentionally exclude Bluetooth depend on a stub component instead
of `rk_ble_hid_host`. The stub exposes the same stable API and reports
`UNAVAILABLE`; NimBLE and `esp_hid` are not compiled. The stub component wrapper
is kept under `rk_ble_hid_host/optional/`, outside the production top-level
component-discovery set, so it cannot silently win link-order resolution in a
Bluetooth-enabled artifact. Targets opt into that directory explicitly. CI
builds an ESP32-S3 fixture for this profile.

### Production-link invariant

The production targets must link `rk_ble_hid_host.c`; a stub that merely
returns `UNAVAILABLE` is only valid for an explicit BLE-disabled target. This
is easy to get wrong because ESP-IDF discovers top-level components by
directory. The optional stub therefore lives outside that discovery set and a
BLE-disabled target names it explicitly.

CI enforces both sides of the contract from the generated build files and link
map:

- Dial and Frame compile the real host and resolve `rk_ble_hid_host_init` from
  its object file;
- neither production map contains the stub; and
- the BLE-off fixture links only the stub and no NimBLE or `esp_hid` object.

Do not accept a green compile alone as evidence that a BLE build contains the
real implementation.

### Resource and scheduler budget

Dial shares internal RAM and radio time between an LVGL/QSPI display, Wi-Fi,
and NimBLE. The shipping profile is intentionally narrow:

| Resource | Production setting | Reason |
| --- | --- | --- |
| Active connections | 1 | One paired media remote is the product requirement. |
| Preferred ATT MTU | 128 bytes | Consumer-control reports do not need the former 256-byte default. |
| NimBLE mbuf/ACL/event pools | Reduced to the single-remote budget | Avoid reserving internal heap for unused throughput and links. |
| NimBLE dynamic allocations | PSRAM (`MEM_ALLOC_MODE_EXTERNAL`) | Protects internal/DMA heap needed by LVGL and display DMA. |
| UI task | Core 1, 32 KiB internal stack | Keeps rendering and its stack away from radio work. |
| NimBLE host/service tasks | Core 0, internal stacks | Co-locates BLE with the Wi-Fi task while retaining cache-safe stacks. |
| Wi-Fi task | Core 0 | Explicit ESP-IDF configuration. |

Task stacks are deliberately **not** moved to PSRAM. ESP-IDF can disable cache
during flash, NVS, and OTA operations; execution stacks used by those paths
must remain internal. “Use PSRAM for NimBLE” means NimBLE's dynamic pools, not
every allocation associated with BLE.

ESP-IDF's current `esp_hid` BLE-host wrapper has a non-obvious configuration
dependency: its symbols are compiled behind `BT_NIMBLE_HID_SERVICE`, which in
turn requires the NimBLE GATT-server and peripheral switches. They remain
enabled solely to satisfy that wrapper even though the application does not
advertise a local HID device. Broadcaster and unrelated standard services stay
disabled. The persistent bond store is set to two entries: ESP-IDF 5.5's
one-entry configuration triggers an out-of-bounds compiler diagnostic in its
sorting implementation. This does not increase the one-active-connection
limit.

### Instrumented coexistence checks

Boot logs report internal/DMA/PSRAM free space and largest blocks after display
allocation, UI initialization, UI-task creation, bridge start, and BLE-host
initialization. They also report early and periodic stack high-water marks and
the actual core for the UI, BLE service, and NimBLE host tasks.

When diagnosing a static Dial display, first establish whether the log reaches
`UI loop task started on core 1`. The pre-BLE portion of boot is already a
useful test: the HID service is created only after Wi-Fi obtains an IP, so a
static display before provisioning does not prove an active BLE connection is
the immediate cause. Compare the before/after UI and BLE memory checkpoints,
then test BLE pairing separately after the UI loop is healthy.

## Coexistence verification

ESP32-S3 shares its 2.4 GHz radio between Wi-Fi and BLE. A successful compile
does not prove coexistence. Before a firmware is released, the exact artifact
must be exercised on its target hardware for:

- cold boot and Wi-Fi provisioning;
- scan, pair, reconnect, disable/re-enable, and forget/reboot;
- playback-state and artwork traffic while remote keys are active;
- Wi-Fi loss and recovery during BLE activity;
- heap and task-stack headroom;
- absence of reset loops or off-task display access.

Frame and Dial require separate hardware evidence even though they share the
same BLE service.
