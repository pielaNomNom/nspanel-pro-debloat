#!/usr/bin/env bash
# Non-interactive batch pattern: run the same disable+purge sequence across
# several panels in one go, no prompts. Useful once you've validated the
# interactive script (../debloat-nspanel.sh) on one panel and just want to
# repeat it on the rest of your fleet.
#
# Usage:
#   PANELS="192.168.1.50 192.168.1.51" CONFIRM=1 ./batch-mode.sh
#
# CONFIRM=1 is required on purpose — this deletes APKs from /system on
# every panel listed, permanently, with no per-device "are you sure?".
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ADB_PORT="${ADB_PORT:-5555}"
PANELS=(${PANELS:-})

if ((${#PANELS[@]} == 0)); then
  echo "Set PANELS=\"ip1 ip2 ...\" (space-separated)." >&2
  exit 1
fi
if [[ "${CONFIRM:-0}" != "1" ]]; then
  echo "Refusing to run without CONFIRM=1 (this is permanent on every panel listed)." >&2
  exit 1
fi

DISABLE_PKGS=(
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
  acr.browser.barebones
  com.android.bluetooth
  com.android.bluetoothmidiservice
  com.android.phone
  com.android.server.telecom
)

DELETE_DIRS=(
  /system/app/kz_app
  /system/app/factoryApp
  /system/app/Browser2
  /system/app/RkDeviceTest
  /system/priv-app/DeviceStorageMonitor
  /system/priv-app/DeviceTest
  /system/app/FDroid
  /system/app/termux
  /system/app/termux_boot
  /system/app/Lightning
  /system/app/Bluetooth
  /system/app/BluetoothMidiService
  /system/priv-app/TeleService
  /system/priv-app/Telecom
  /system/priv-app/TelephonyProvider
  /oem/bundled_persist-app/CoolKit_24092415
  /oem/bundled_persist-app/FDroid
  /vendor/app/RkApkinstaller
)

adb start-server >/dev/null 2>&1 || true

for ip in "${PANELS[@]}"; do
  adb connect "${ip}:${ADB_PORT}" >/dev/null 2>&1 || true
done

echo "Connected devices:"
adb devices | awk 'NR>1 && $2=="device"{print "  "$1}'

for ip in "${PANELS[@]}"; do
  dev="${ip}:${ADB_PORT}"
  echo
  echo "========== $dev: disable =========="
  adb -s "$dev" shell "svc bluetooth disable" </dev/null 2>/dev/null || true
  adb -s "$dev" shell "settings put global bluetooth_on 0" </dev/null 2>/dev/null || true

  for p in "${DISABLE_PKGS[@]}"; do
    echo "— disable $p"
    adb -s "$dev" shell "am force-stop $p" </dev/null 2>/dev/null || true
    adb -s "$dev" shell "pm disable-user --user 0 $p" </dev/null 2>/dev/null || \
      adb -s "$dev" shell "su -c 'pm disable $p'" </dev/null 2>/dev/null || \
      echo "  (skip/fail)"
  done

  echo
  echo "========== $dev: purge /system =========="
  remote="/data/local/tmp/nspanel_purge.sh"
  tmp=$(mktemp)
  {
    echo '#!/system/bin/sh'
    echo 'mount -o remount,rw /system'
    echo 'mount -o remount,rw /oem 2>/dev/null'
    echo 'mount -o remount,rw /vendor 2>/dev/null'
    echo 'setenforce 0 2>/dev/null'
    for d in "${DELETE_DIRS[@]}"; do
      printf 'if [ -e %s ]; then du -sh %s; rm -rf %s && echo DELETED %s || echo FAIL %s; else echo SKIP %s; fi\n' \
        "$d" "$d" "$d" "$d" "$d" "$d"
    done
    echo 'rm -rf /data/app/com.eWeLinkControlPanel-* /data/app/org.fdroid.fdroid-* 2>/dev/null'
    echo 'rm -rf /data/data/com.eWeLinkControlPanel /data/data/org.fdroid.fdroid /data/data/com.termux /data/data/com.termux.boot /data/data/acr.browser.barebones /data/data/com.eWeLinkNSPro.dev 2>/dev/null'
    echo 'for p in com.eWeLinkControlPanel org.fdroid.fdroid com.eWeLinkNSPro.dev; do pm uninstall --user 0 "$p" 2>/dev/null; done'
    echo 'sync'
    echo 'mount -o remount,ro /system 2>/dev/null'
    echo 'mount -o remount,ro /oem 2>/dev/null'
    echo 'mount -o remount,ro /vendor 2>/dev/null'
    echo 'df -h /system /oem /vendor /data'
    echo 'echo PURGE_DONE'
  } >"$tmp"

  adb -s "$dev" push "$tmp" "$remote" >/dev/null
  rm -f "$tmp"
  adb -s "$dev" shell "su -mm -c 'chmod 755 $remote; $remote'" </dev/null

  echo
  echo "========== $dev: post status =========="
  adb -s "$dev" shell "grep -E 'MemTotal|MemAvailable' /proc/meminfo" </dev/null
done

echo
echo "ALL_DONE"
