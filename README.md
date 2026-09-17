# NSPanel Pro Debloat

Interactive helper to strip factory bloatware from a **Sonoff NSPanel Pro**
(Rockchip `px30`, Android 8.1) down to a minimal, low-RAM setup — typically
used to run it as a dedicated **Home Assistant** wall panel.

> Tested on NSPanel Pro units running firmware 4.0.12 / 4.1.3. Should work
> on other Rockchip-based NSPanel Pro firmware versions, but **always take
> a backup / know your recovery path before touching `/system`.**

## Why

Out of the box, the panel ships with a pile of stuff you probably don't
need if it's only running Home Assistant: eWeLink's own control app (and
its Matter/Zigbee/Hue/WebSocket stack), F-Droid, Termux, device-test
tools, an APK installer, Bluetooth/telephony stacks with nothing to talk
to, a stub browser, etc. On a 2 GB panel with a nearly-full `/system`,
that's the difference between "smooth" and "swapping."

This script does two things:

1. **Disable** (layer 1, fast & reversible) — `pm disable-user` on the
   known-bloat packages, force-stopped and Bluetooth turned off.
2. **Delete** (layer 2, permanent) — remove the underlying APKs from
   `/system` / `/oem` / `/vendor`, because on a full `/system` partition
   `pm disable-user` alone doesn't free any space.

Home Assistant Companion, your launcher, and NSPanel Pro Tools are never
touched.

## Requirements

- `adb` (Android Platform Tools) on your machine
- Root on the panel (SuperSU) — required for the `/system` remount and
  the layer-2 deletion step
- Bash (macOS/Linux natively; Windows via Git Bash / WSL)
- Optional: `nmap` for a fast network scan (falls back to a pure-bash
  scan if missing), `dns-sd` (macOS) or `avahi-browse` (Linux) for mDNS
  discovery

## Quick start

```bash
git clone https://github.com/<you>/nspanel-pro-debloat.git
cd nspanel-pro-debloat
./debloat-nspanel.sh
```

```
NSPanel Pro debloat — menu

  1) Discover panels (adb + known IPs + subnet scan + mDNS)
  2) Enable ADB over Wi-Fi (tcpip 5555) on selected device
  3) Status (RAM, /system, processes, remaining bloat)
  4) Disable bloat packages + turn off Bluetooth
  5) Delete APKs from /system (su -mm) — PERMANENT
  6) Full debloat (4+5) + optional reboot
  7) Install essentials from ./apks (launcher / F-Droid / tools)
  8) Reboot
  h) Help
  q) Quit
```

Typical first run: **1** (find the panel) → **3** (see current state) →
**4** (safe, reversible cleanup) → **3** again → if you're happy, **5**
(permanent) → **8**.

### Dry run

Preview every command without touching the device:

```bash
DRY_RUN=1 ./debloat-nspanel.sh
```

### Connecting to a panel

ADB over Wi-Fi needs to be enabled once (over USB, or from the panel's
own developer settings if available):

```bash
adb tcpip 5555
adb connect <panel-ip>:5555
```

The script's **Discover** option automates this: it tries any IPs you've
pre-configured, scans your local `/24` for open `tcp/5555`, and (if
available) browses mDNS for `_adb._tcp`.

### Pre-seeding known panel IPs (optional)

Copy `panels.conf.example` to `panels.conf` (gitignored) and list IPs you
already know, so **Discover** connects to them directly without waiting
on the subnet scan:

```bash
cp panels.conf.example panels.conf
```

## What gets touched

### Layer 1 — `pm disable-user` (fast, reversible)

```
com.eWeLinkControlPanel
com.eWeLinkNSPro.dev
org.chromium.webview_shell
com.rockchip.devicetest
com.smatek.test
com.smatek.devicestoragemonitor
com.DeviceTest
com.android.apkinstaller
org.fdroid.fdroid
com.termux
com.termux.boot
acr.browser.barebones          # "Lightning" browser
com.android.bluetooth
com.android.bluetoothmidiservice
com.android.phone
com.android.server.telecom
```

Plus: `svc bluetooth disable` / `settings put global bluetooth_on 0`.

### Layer 2 — deletion from `/system` `/oem` `/vendor` (permanent, frees space)

| Package / thing        | Path |
|-------------------------|------|
| eWeLink                 | `/system/app/kz_app` |
| factory / NSPro.dev      | `/system/app/factoryApp` |
| webview_shell            | `/system/app/Browser2` |
| RkDeviceTest             | `/system/app/RkDeviceTest` |
| DeviceStorageMonitor     | `/system/priv-app/DeviceStorageMonitor` |
| DeviceTest               | `/system/priv-app/DeviceTest` |
| F-Droid                  | `/system/app/FDroid`, `/oem/bundled_persist-app/FDroid` |
| Termux                   | `/system/app/termux`, `/system/app/termux_boot` |
| Lightning browser        | `/system/app/Lightning` |
| Bluetooth                | `/system/app/Bluetooth`, `/system/app/BluetoothMidiService` |
| Phone/Telecom            | `/system/priv-app/TeleService`, `Telecom`, `TelephonyProvider` |
| CoolKit test             | `/oem/bundled_persist-app/CoolKit_24092415` |
| APK installer            | `/vendor/app/RkApkinstaller` |

Actual paths can differ slightly between firmware versions — the script
skips anything that isn't present, and `Status` (option 3) shows you
what's still installed before you commit to deleting.

**Important:** on these panels, a plain `su -c 'mount -o remount,rw
/system'` often silently fails. The script uses SuperSU's mount-master
mode (`su -mm -c '...'`), which is what actually works.

## Install essentials (optional)

Option **7** installs whatever `.apk` files you drop into `./apks/`
(gitignored, not bundled with this repo — grab them from your own
trusted source):

- a lightweight launcher (e.g. a minimal home-screen replacement)
- F-Droid, if you want a way to sideload/update other apps later
- NSPanel Pro Tools, if it's not already on your panel

This repo intentionally does **not** ship or auto-download any
third-party APKs — you choose where those come from.

## Reverting

Re-enable a disabled package:

```bash
adb -s <ip>:5555 shell pm enable <package.name>
```

Deleted APKs only come back via an OTA update, a manual APK reinstall,
or restoring a partition backup — **back up first if you're not sure.**

## Don't

- Flash an *older* firmware over a newer one "to fix something" — that's
  a downgrade and can bring eWeLink back.
- Run layer 2 (delete) without knowing Home Assistant Companion / your
  launcher / NSPanel Pro Tools are confirmed working first.
- Disable `com.android.webview` — Home Assistant Companion needs it.

## License

MIT — see [LICENSE](LICENSE).
