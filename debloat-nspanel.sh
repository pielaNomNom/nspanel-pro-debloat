#!/usr/bin/env bash
# Interactive debloat helper for Sonoff NSPanel Pro (Rockchip px30, Android 8.1).
# Strips factory bloatware down to a minimal "Home Assistant + launcher" setup.
# Requires: adb, root (SuperSU) on the panel. Optional: nmap, dns-sd/avahi-browse.
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB_PORT="${ADB_PORT:-5555}"
APK_DIR="${APK_DIR:-$SCRIPT_DIR/apks}"
DRY_RUN="${DRY_RUN:-0}"

# Optional local config (gitignored) — pre-seed panels you already know about:
#   KNOWN_IPS=(192.168.1.50 192.168.1.51)
KNOWN_IPS=()
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/panels.conf}"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Packages to disable (layer 1 — fast, reversible)
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

# System dirs to delete (layer 2 — frees /system space, permanent)
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

# Known-good lightweight replacements, installed from local APK files you provide
# (see "Install essentials" in the README — these are not bundled in this repo).
ESSENTIAL_APK_HINTS=(
  "cclauncher*.apk        -> lightweight launcher"
  "fdroid*.apk            -> F-Droid, for sideloading updates later"
  "nspanelpro-tools*.apk  -> NSPanel Pro Tools (community)"
)

KEEP_HINT="Home Assistant / launcher / NSPanel Pro Tools are left untouched."

die() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Missing tool: $1"; }
is_dry() { [[ "$DRY_RUN" == "1" ]]; }
note_dry() { is_dry && echo "  [dry-run] $*"; }

need adb

adb_start() {
  adb start-server >/dev/null 2>&1 || true
}

list_devices() {
  adb devices | awk 'NR>1 && $2=="device" {print $1}'
}

pick_device() {
  local devices=()
  local d i
  while IFS= read -r d; do
    [[ -n "$d" ]] && devices+=("$d")
  done < <(list_devices)

  if ((${#devices[@]} == 0)); then
    echo "No connected devices (state 'device'). Run 'Discover panels' first."
    return 1
  fi

  if ((${#devices[@]} == 1)); then
    DEVICE="${devices[0]}"
    echo "Using the only connected device: $DEVICE"
    return 0
  fi

  echo "Available devices:"
  for i in "${!devices[@]}"; do
    local host ver
    host=$(adb -s "${devices[$i]}" shell getprop net.hostname </dev/null 2>/dev/null | tr -d '\r' || true)
    ver=$(adb -s "${devices[$i]}" shell getprop ro.build.display.id </dev/null 2>/dev/null | tr -d '\r' || true)
    printf "  [%d] %s  (%s, FW %s)\n" "$((i + 1))" "${devices[$i]}" "${host:-?}" "${ver:-?}"
  done
  printf "Number (1-%d): " "${#devices[@]}"
  read -r choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#devices[@]})); then
    echo "Cancelled."
    return 1
  fi
  DEVICE="${devices[$((choice - 1))]}"
  echo "Selected: $DEVICE"
}

shell() {
  adb -s "$DEVICE" shell "$@" </dev/null
}

su_c() {
  adb -s "$DEVICE" shell "su -c $(printf '%q' "$*")" </dev/null
}

# --- discovery --------------------------------------------------------------

local_subnet_prefix() {
  # Best-effort /24 guess from the default-route interface IP.
  local ip=""
  if command -v ip >/dev/null; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  fi
  if [[ -z "$ip" ]] && command -v ipconfig >/dev/null; then
    ip=$(ipconfig 2>/dev/null | awk -F': ' '/IPv4 Address/{gsub(/\r/,"",$2); print $2; exit}')
  fi
  if [[ -z "$ip" ]] && command -v ifconfig >/dev/null; then
    ip=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)
  fi
  [[ -n "$ip" ]] && echo "${ip%.*}"
}

scan_subnet() {
  # NOTE: status lines go to stderr — stdout is reserved for "ip:port" hits,
  # since callers capture this function's stdout with $(...).
  local prefix
  prefix=$(local_subnet_prefix)
  if [[ -z "$prefix" ]]; then
    echo "Could not determine local subnet — skipping scan." >&2
    return 0
  fi
  echo "Scanning ${prefix}.0/24 for tcp/$ADB_PORT…" >&2
  if command -v nmap >/dev/null; then
    nmap -p "$ADB_PORT" --open -T4 "${prefix}.0/24" 2>/dev/null \
      | awk -v port="$ADB_PORT" '/Nmap scan report/{ip=$NF; gsub(/[()]/,"",ip)} /open/{print ip":"port}'
    return 0
  fi

  # Portable fallback: parallel /dev/tcp probes, each capped at 1s so a
  # /24 finishes in a couple of seconds instead of hitting the OS's own
  # (often 20s+) connect timeout for every unused address.
  local use_timeout=0
  command -v timeout >/dev/null && use_timeout=1

  local host pids=()
  for host in $(seq 1 254); do
    (
      if ((use_timeout)); then
        timeout 1 bash -c "exec 3<>/dev/tcp/${prefix}.${host}/${ADB_PORT}" \
          && echo "${prefix}.${host}:${ADB_PORT}"
      else
        exec 3<>"/dev/tcp/${prefix}.${host}/${ADB_PORT}" \
          && echo "${prefix}.${host}:${ADB_PORT}"
      fi
    ) 2>/dev/null &
    pids+=($!)
    if (( ${#pids[@]} >= 128 )); then
      wait "${pids[@]}" 2>/dev/null
      pids=()
    fi
  done
  wait 2>/dev/null
}

cmd_discover() {
  echo "=== adb devices ==="
  adb devices -l
  echo

  if ((${#KNOWN_IPS[@]} > 0)); then
    echo "=== known IPs from $CONFIG_FILE ==="
    local ip
    for ip in "${KNOWN_IPS[@]}"; do
      adb connect "$ip:$ADB_PORT" || true
    done
    echo
  fi

  echo "=== subnet scan ==="
  local found
  found=$(scan_subnet)
  if [[ -n "$found" ]]; then
    echo "$found" | while read -r hostport; do
      echo "  OPEN  $hostport → connect…"
      adb connect "$hostport" || true
    done
  else
    echo "  (nothing found — check panels are on the same network/VLAN)"
  fi
  echo

  if command -v dns-sd >/dev/null; then
    echo "=== mDNS _adb._tcp (3s, macOS) ==="
    dns-sd -B _adb._tcp local. &
    local pid=$!
    sleep 3
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo
  elif command -v avahi-browse >/dev/null; then
    echo "=== mDNS _adb._tcp (3s, Linux) ==="
    timeout 3 avahi-browse -rt _adb._tcp 2>/dev/null || true
    echo
  fi

  echo "Currently connected:"
  list_devices | sed 's/^/  /' || echo "  (none)"
}

cmd_wifi_enable_usb() {
  pick_device || return 1
  echo "Enabling ADB over TCP ($ADB_PORT) on $DEVICE…"
  adb -s "$DEVICE" tcpip "$ADB_PORT"
  printf "Persist across reboots too (root)? [y/N]: "
  read -r ans
  if [[ "$ans" =~ ^[yY]$ ]]; then
    su_c "setprop persist.adb.tcp.port $ADB_PORT" || true
    echo "persist.adb.tcp.port=$ADB_PORT"
  fi
  local ip
  ip=$(shell "ip -f inet addr show wlan0" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)
  echo "wlan0 IP: ${ip:-unknown}"
  [[ -n "${ip:-}" ]] && adb connect "$ip:$ADB_PORT" || true
}

cmd_status() {
  pick_device || return 1
  echo "=== STATUS $DEVICE ==="
  shell "echo hostname=\$(getprop net.hostname); echo fw=\$(getprop ro.build.display.id); echo serial=\$(getprop ro.serialno); echo product=\$(getprop ro.product.version)"
  shell "grep -E 'MemTotal|MemFree|MemAvailable' /proc/meminfo"
  shell "df -h /system /oem /vendor /data 2>/dev/null | tail -n +1"
  echo "--- top RSS ---"
  shell "ps -A -o RSS,NAME" 2>/dev/null | sort -nr | head -15
  echo "--- bluetooth_on ---"
  shell "settings get global bluetooth_on"
  echo "--- bloat still present ---"
  local p
  for p in "${DISABLE_PKGS[@]}"; do
    local path
    path=$(shell "pm path $p" 2>/dev/null | tr -d '\r' || true)
    [[ -n "$path" ]] && echo "  $p → $path"
  done
}

cmd_disable() {
  pick_device || return 1
  echo "$KEEP_HINT"
  is_dry && echo "[DRY RUN — nothing will actually change]"
  printf "Disable + force-stop bloat packages on $DEVICE. Continue? [y/N]: "
  read -r ans
  [[ "$ans" =~ ^[yY]$ ]] || { echo "Cancelled."; return 0; }

  if is_dry; then
    note_dry "svc bluetooth disable"
    note_dry "settings put global bluetooth_on 0"
  else
    shell "svc bluetooth disable" 2>/dev/null || true
    shell "settings put global bluetooth_on 0" 2>/dev/null || true
    shell "am force-stop com.android.settings" 2>/dev/null || true
  fi

  local p
  for p in "${DISABLE_PKGS[@]}"; do
    echo "— $p"
    if is_dry; then
      note_dry "pm disable-user --user 0 $p"
      continue
    fi
    shell "am force-stop $p" 2>/dev/null || true
    shell "pm disable-user --user 0 $p" 2>/dev/null || \
      su_c "pm disable $p" 2>/dev/null || \
      echo "  (failed / package not present)"
  done
  is_dry || su_c "killall node index.js 2>/dev/null; true" 2>/dev/null || true
  echo "Done. A reboot is recommended."
}

cmd_delete_system() {
  pick_device || return 1
  echo "$KEEP_HINT"
  echo "WARNING: deletes APKs from /system /oem /vendor (PERMANENT). Uses su -mm."
  is_dry && echo "[DRY RUN — nothing will actually change]"
  printf "Really proceed on $DEVICE? Type YES: "
  read -r ans
  [[ "$ans" == "YES" ]] || { echo "Cancelled."; return 0; }

  if is_dry; then
    local d
    for d in "${DELETE_DIRS[@]}"; do
      note_dry "would delete $d (if present)"
    done
    return 0
  fi

  # Build a remote script — avoids quoting headaches over adb shell.
  local remote="/data/local/tmp/nspanel_purge.sh"
  local tmp
  tmp=$(mktemp)
  {
    echo '#!/system/bin/sh'
    echo 'mount -o remount,rw /system'
    echo 'mount -o remount,rw /oem 2>/dev/null'
    echo 'mount -o remount,rw /vendor 2>/dev/null'
    echo 'setenforce 0 2>/dev/null'
    local d
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

  adb -s "$DEVICE" push "$tmp" "$remote"
  rm -f "$tmp"
  adb -s "$DEVICE" shell "su -mm -c 'chmod 755 $remote; $remote'"
  echo "Purge finished (check PURGE_DONE above). A reboot is recommended."
}

cmd_install_essentials() {
  pick_device || return 1
  echo "Installs lightweight replacements from local APK files in: $APK_DIR"
  echo "(this repo does not bundle any APKs — you provide your own, see README):"
  local hint
  for hint in "${ESSENTIAL_APK_HINTS[@]}"; do echo "  $hint"; done
  echo

  if [[ ! -d "$APK_DIR" ]]; then
    echo "No such directory: $APK_DIR — create it and drop APK files in, or set APK_DIR."
    return 1
  fi

  shopt -s nullglob
  local apks=("$APK_DIR"/*.apk)
  shopt -u nullglob
  if ((${#apks[@]} == 0)); then
    echo "No .apk files found in $APK_DIR."
    return 0
  fi

  echo "Found:"
  local f
  for f in "${apks[@]}"; do echo "  $(basename "$f")"; done
  printf "Install all of the above on $DEVICE? [y/N]: "
  read -r ans
  [[ "$ans" =~ ^[yY]$ ]] || { echo "Cancelled."; return 0; }

  for f in "${apks[@]}"; do
    echo "— installing $(basename "$f")"
    if is_dry; then
      note_dry "adb install -r $f"
      continue
    fi
    adb -s "$DEVICE" install -r "$f" || echo "  install failed for $(basename "$f")"
  done
}

cmd_full() {
  cmd_disable || return 1
  cmd_delete_system || return 1
  printf "Reboot now? [y/N]: "
  read -r ans
  if [[ "$ans" =~ ^[yY]$ ]]; then
    cmd_reboot
  fi
}

cmd_reboot() {
  pick_device || return 1
  echo "Rebooting $DEVICE…"
  is_dry && { note_dry "adb reboot"; return 0; }
  adb -s "$DEVICE" reboot
  echo "Waiting for it to come back (up to ~2 min)…"
  local i
  for i in $(seq 1 24); do
    sleep 5
    local ip
    for ip in "${KNOWN_IPS[@]}"; do
      adb connect "$ip:$ADB_PORT" >/dev/null 2>&1 || true
    done
    if list_devices | grep -q .; then
      echo "Back online:"
      list_devices | sed 's/^/  /'
      return 0
    fi
    echo "  … attempt $i"
  done
  echo "Timeout — check manually: adb devices / adb connect IP:$ADB_PORT"
}

cmd_help() {
  cat <<EOF
NSPanel Pro debloat — menu   $(is_dry && echo "[DRY RUN MODE]")

  1) Discover panels (adb + known IPs + subnet scan + mDNS)
  2) Enable ADB over Wi-Fi (tcpip $ADB_PORT) on selected device
  3) Status (RAM, /system, processes, remaining bloat)
  4) Disable bloat packages + turn off Bluetooth
  5) Delete APKs from /system (su -mm) — PERMANENT
  6) Full debloat (4+5) + optional reboot
  7) Install essentials from ./apks (launcher / F-Droid / tools)
  8) Reboot
  h) Help
  q) Quit

$KEEP_HINT
Run with DRY_RUN=1 ./debloat-nspanel.sh to preview without changing anything.
EOF
}

main() {
  adb_start
  DEVICE=""
  cmd_help
  while true; do
    echo
    printf "Choice: "
    read -r opt
    case "$opt" in
      1) cmd_discover ;;
      2) cmd_wifi_enable_usb ;;
      3) cmd_status ;;
      4) cmd_disable ;;
      5) cmd_delete_system ;;
      6) cmd_full ;;
      7) cmd_install_essentials ;;
      8) cmd_reboot ;;
      h|H) cmd_help ;;
      q|Q) echo "Bye."; exit 0 ;;
      *) echo "Unknown option." ;;
    esac
  done
}

main "$@"
