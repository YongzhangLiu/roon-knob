
---

## Firmware maturity

- **HiPhi Dial — Beta:** physically exercised on current hardware, including
  display, Wi-Fi, artwork, settings persistence, and BLE media-remote control.
- **HiPhi Frame — Alpha:** packaged for early hardware testing. The current
  shared-stack build has not completed equivalent Frame regression coverage;
  expect rough edges and report target-specific failures.

## Updating

**OTA (existing users):** Update the control service, restart, knob updates automatically.

**Docker Compose:**
```yaml
# Unified Hi-Fi Control - supports Roon, Lyrion (LMS), and OpenHome
services:
  unified-hifi-control:
    image: docker.io/muness/unified-hifi-control:latest
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: America/New_York
    volumes:
      - unified-hifi-control-data:/home/node/app/data
volumes:
  unified-hifi-control-data:
```

> **Note:** Legacy image `muness/roon-extension-knob` still works and receives the same updates.

Then: `docker compose pull && docker compose up -d`

---

<details>
<summary><b>First-time flashing instructions</b></summary>

### Web Flasher (Recommended)

Use the [web flasher](https://roon-knob.muness.com/flash.html) in Chrome/Edge - no tools to install.

### Command Line (esptool.py)

```bash
pip install esptool
esptool.py --chip esp32s3 -p /dev/cu.usbmodem* write_flash 0x0 hiphi_dial_merged.bin
```

`roon_knob_merged.bin` is a byte-identical compatibility alias for `hiphi_dial_merged.bin`.

**Troubleshooting:** If you get "No serial data received", retry a few times or try another cable.

</details>
