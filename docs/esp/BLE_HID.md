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
