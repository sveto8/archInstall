#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: Base install with LUKS2 + Btrfs  ("Phase 0")
#
# Run this from the Arch ISO LIVE environment (not from an
# already-installed system). It WIPES the target device.
#
# The UI is dialog-based: ALL questions are asked up front (disk,
# user + password, LUKS passphrase, clock, Wake-on-LAN, Wi-Fi,
# desktop environment), followed by one summary and the typed WIPE
# confirmation. After that the install runs unattended with live
# output in a dialog box.
#
# Produces exactly the layout expected by setupAfterInstall.sh:
#
#   /efi         unencrypted ESP  (FAT32)
#   /boot        unencrypted      (ext4)
#
#   LUKS2
#     └── Btrfs
#          ├── @             -> /
#          ├── @home        -> /home
#          └── @snapshots   -> /.snapshots
#
# Optionally installs GNOME, KDE Plasma or XFCE right away by running
# installDE.sh inside the new system (non-interactive). After reboot run
# setupAfterInstall.sh (Snapper/GRUB/Plymouth) and installApps.sh.
# ============================================================

# ---------------- CONFIGURATION (edit before running) ----------------

ESP_SIZE="1GiB"
BOOT_SIZE="4GiB"                # rest of the disk goes to the LUKS/Btrfs partition
# Defaults only -- hostname, timezone and keymap are confirmed/changed in
# dialogs below (a different hostname per machine, e.g. laptop vs desktop).
NEW_HOSTNAME="monarch"
TIMEZONE="Europe/Zagreb"
LOCALE="en_US.UTF-8"             # primary locale -> goes into /etc/locale.conf as LANG
LOCALES=("en_US.UTF-8" "hr_HR.UTF-8")   # all locales generated (the primary one is always included)
KEYMAP="us"
# 'ssd' is appended automatically when the target disk is non-rotational.
MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_url="${ARCH_REPO_URL:-https://raw.githubusercontent.com/sveto8/archInstall/main}"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    # Download to a temporary file FIRST (never write a partial file
    # directly next to the script -- the folder may be a read-only or
    # permission-quirky mount, e.g. a VM shared folder where root cannot
    # write). Verify the download produced a non-empty file, then move
    # it into place. If the script folder turns out to be unwritable,
    # fall back to keeping lib.sh in $TMPDIR and source it from there.
    _lib_tmp="$(mktemp "${TMPDIR:-/tmp}/lib.sh.XXXXXX")" || {
        echo "ERROR: could not create a temporary file for lib.sh." >&2
        exit 1
    }
    _code="$(curl -fsSL -o "$_lib_tmp" -w '%{http_code}' \
        "${_repo_url}/lib.sh" 2>/dev/null || true)"
    if [[ -s "$_lib_tmp" ]]; then
        if mv "$_lib_tmp" "$SCRIPT_DIR/lib.sh" 2>/dev/null; then
            :
        else
            _lib_fallback="${TMPDIR:-/tmp}/archInstall-lib.sh"
            mv "$_lib_tmp" "$_lib_fallback"
            echo "NOTE: $SCRIPT_DIR is not writable; using $_lib_fallback instead." >&2
            SCRIPT_DIR="$(dirname "$_lib_fallback")"
        fi
    else
        rm -f "$_lib_tmp"
        echo "ERROR: lib.sh is missing next to $0 and could not be downloaded." >&2
        echo "       URL: ${_repo_url}/lib.sh (HTTP ${_code:-000})" >&2
        echo "       Put lib.sh (and the other scripts) in the same folder as archInstall.sh and run it again." >&2
        exit 1
    fi
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# The primary locale must always be generated.
in_array "$LOCALE" "${LOCALES[@]}" || LOCALES+=("$LOCALE")
LOCALES_STR="${LOCALES[*]}"
GRUB_TARGET="$(efi_grub_target)"

BACKTITLE="Arch Linux installer -- base system"
LOG_FILE="/root/archInstall.log"

trap 'die "Failed at line $LINENO."' ERR

# ---------------- BASIC CHECKS ----------------

[[ $EUID -eq 0 ]] || die "Run this script as root (from the Arch ISO live environment)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode."

command -v sgdisk >/dev/null || die "sgdisk not found (package: gptfdisk)."
command -v cryptsetup >/dev/null || die "cryptsetup not found."
command -v mkfs.btrfs >/dev/null || die "mkfs.btrfs not found (package: btrfs-progs)."
command -v pacstrap >/dev/null || die "pacstrap not found (are you on the Arch ISO?)."

ensure_dialog
ui_init

# This script wipes a whole disk and is meant for the live ISO only.
if ! is_live_iso; then
    ask_yes "Not the live ISO" "This does not look like the Arch live ISO.\n\nThis installer WIPES a whole disk and is meant to be run from the live ISO.\n\nContinue anyway?" no || abort
fi

# ============================================================
# QUESTIONS (nothing is changed on disk until the WIPE confirmation)
# ============================================================

# ---------------- SELECT DISK ----------------

# The disk the live medium itself booted from must never be offered.
LIVE_DISK=""
_live_src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
if [[ -n "$_live_src" && -b "$_live_src" ]]; then
    _live_pk="$(lsblk -no PKNAME "$_live_src" 2>/dev/null | head -n1 || true)"
    [[ -z "$_live_pk" ]] || LIVE_DISK="/dev/${_live_pk}"
fi

DISK_ITEMS=()
while read -r name size type; do
    [[ "$type" == "disk" ]] || continue
    [[ "$name" == /dev/zram* ]] && continue          # compressed-RAM swap shows up as a "disk" on the ISO
    [[ -n "$LIVE_DISK" && "$name" == "$LIVE_DISK" ]] && continue
    model="$(lsblk -dno MODEL "$name" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    mounted=""
    if [[ -n "$(lsblk -no MOUNTPOINTS "$name" 2>/dev/null | tr -d '[:space:]')" ]]; then
        mounted="  [has mounted partitions]"
    fi
    DISK_ITEMS+=("$name" "${size}  ${model:-unknown model}${mounted}")
done < <(lsblk -dpno NAME,SIZE,TYPE)

[[ "${#DISK_ITEMS[@]}" -gt 0 ]] || die "No disks found."

DEVICE="$(dlg_capture --title "Target disk" \
    --menu "Select the disk to install Arch onto.\n\nEVERYTHING ON THE SELECTED DISK WILL BE ERASED." \
    0 "$BOX_W" 0 "${DISK_ITEMS[@]}")" || abort
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Refuse to run against something that is currently mounted (e.g. the live USB itself),
# but offer to clean up leftover mounts from a previous, interrupted run of this script.
if [[ -n "$(lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null | tr -d '[:space:]')" ]]; then
    ask_yes "Active mounts" "$DEVICE (or a partition on it) has active mounts, possibly left over from a previous run:\n\n$(lsblk -l -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$DEVICE")\n\nUnmount everything under $DEVICE and continue?" yes \
        || die "$DEVICE (or a partition on it) is currently mounted. Refusing to touch it."
    log "Unmounting leftover mounts..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    sleep 1
    STILL_MOUNTED="$(lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$STILL_MOUNTED" ]]; then
        die "Could not fully unmount $DEVICE. Unmount manually (umount -R /mnt; cryptsetup close cryptroot) and re-run."
    fi
    info "Unmounted and closed cryptroot successfully."
fi

# partition suffix: a device name that ends in a digit gets a "p"
# (/dev/nvme0n1 -> nvme0n1p1, /dev/mmcblk0 -> mmcblk0p1, /dev/loop0 -> loop0p1),
# otherwise none (/dev/sda -> sda1, /dev/vda -> vda1).
if [[ "$DEVICE" =~ [0-9]$ ]]; then
    SUF="p"
else
    SUF=""
fi
ESP="${DEVICE}${SUF}1"
BOOTPART="${DEVICE}${SUF}2"
LUKSPART="${DEVICE}${SUF}3"

# Btrfs 'ssd' mount option only for non-rotational disks.
if [[ "$(cat "/sys/block/$(basename "$DEVICE")/queue/rotational" 2>/dev/null || echo 0)" == "0" ]]; then
    MOUNT_OPTS+=",ssd"
fi

UCODE_PKG=""
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
    UCODE_PKG="amd-ucode"
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
    UCODE_PKG="intel-ucode"
fi

# ---------------- HOSTNAME / TIMEZONE / KEYMAP ----------------

while true; do
    ask_text NEW_HOSTNAME "Hostname" "Hostname of this machine (letters, digits and '-', max 63 characters).\n\nTip: use a different name on every machine (e.g. laptop / desktop)." "$NEW_HOSTNAME" || abort
    [[ "$NEW_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] && break
    msg_box "Invalid hostname" "'$NEW_HOSTNAME' is not a valid hostname."
done

while true; do
    ask_text TIMEZONE "Timezone" "Timezone as Region/City (for example Europe/Zagreb):" "$TIMEZONE" || abort
    [[ -n "$TIMEZONE" && "$TIMEZONE" != *..* && -f "/usr/share/zoneinfo/$TIMEZONE" ]] && break
    msg_box "Invalid timezone" "'$TIMEZONE' was not found in /usr/share/zoneinfo.\n\nExample: Europe/Zagreb (list: timedatectl list-timezones)."
done

_keymaps="$(localectl list-keymaps 2>/dev/null || true)"
while true; do
    ask_text KEYMAP "Console keymap" \
        "Console keymap(s). Use one name, or several separated by commas (or spaces).\n\nExamples:\n  us          -- US only\n  croat       -- Croatian only\n  us,croat    -- US + Croatian (stacked; the last one wins)\n\nList: localectl list-keymaps" \
        "$KEYMAP" || abort

    # Split the input on commas and/or whitespace, validate each name
    # against the keymap list, and store the result back as a normalized
    # comma-separated string -- the canonical internal form (the split
    # into primary + toggle happens further down, before the chroot).
    read -r -a _km_arr <<< "${KEYMAP//,/ }"
    _km_ok=(); _km_bad=()
    for _km in "${_km_arr[@]}"; do
        [[ -n "$_km" ]] || continue
        if [[ -z "$_keymaps" ]] || grep -qxF -- "$_km" <<< "$_keymaps"; then
            _km_ok+=("$_km")
        else
            _km_bad+=("$_km")
        fi
    done

    if [[ "${#_km_ok[@]}" -eq 0 ]]; then
        msg_box "Keymap" "No valid keymap given.\n\nList: localectl list-keymaps"
        continue
    fi
    if [[ "${#_km_bad[@]}" -gt 0 ]]; then
        msg_box "Unknown keymap" "Unknown keymap(s): ${_km_bad[*]}\n\nList: localectl list-keymaps"
        continue
    fi

    KEYMAP="$(IFS=,; printf '%s' "${_km_ok[*]}")"
    break
done

# ---------------- SYSTEM LANGUAGE (primary locale) ----------------

LOCALE="$(dlg_capture --title "System language" --default-item "$LOCALE" \
    --menu "Which language should the system use by default (LANG in /etc/locale.conf)?" \
    0 "$BOX_W" 0 \
    en_US.UTF-8 "English (United States)" \
    hr_HR.UTF-8 "Croatian (Hrvatska)")" || abort

in_array "$LOCALE" "${LOCALES[@]}" || LOCALES+=("$LOCALE")
LOCALES_STR="${LOCALES[*]}"

# ---------------- USER ACCOUNT + PASSWORD ----------------

NEW_USERNAME=""
MAKE_SUDO="no"
USER_PASS=""
ROOT_PASS=""
SET_ROOT_PASSWORD="no"

while true; do
    ask_text NEW_USERNAME "New user" "Username for the new regular user.\n\nLeave empty to skip (then only root will exist)." "" || abort
    if [[ -z "$NEW_USERNAME" ]]; then
        break
    fi
    if [[ "$NEW_USERNAME" == "root" || ! "$NEW_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        msg_box "Invalid username" "'$NEW_USERNAME' is not allowed.\n\nUse lowercase letters, digits, '_' or '-', starting with a letter or '_' (and not 'root')."
        continue
    fi
    break
done

if [[ -n "$NEW_USERNAME" ]]; then
    if ask_yes "Superuser" "Should $NEW_USERNAME be a superuser?\n\n(added to the 'wheel' group, can use sudo)" yes; then
        MAKE_SUDO="yes"
    fi
    ask_password USER_PASS "Password for $NEW_USERNAME" || abort
fi

if [[ -n "$NEW_USERNAME" && "$MAKE_SUDO" == "yes" ]]; then
    SET_ROOT_PASSWORD="no"
else
    SET_ROOT_PASSWORD="yes"
    ROOT_INTRO="No sudo-enabled user will exist, so the root account needs a password to be able to log in."
    ask_password ROOT_PASS "Root password" "$ROOT_INTRO" || abort
fi

# ---------------- DISK ENCRYPTION PASSPHRASE ----------------

LUKS_INTRO="The root partition will be encrypted with LUKS2.\n\nChoose the passphrase you will type at every boot. There is NO way to recover the data if you forget it."
ask_password LUKS_PASS "LUKS passphrase" "$LUKS_INTRO" || abort

# ---------------- HARDWARE CLOCK (RTC) ----------------

RTC_MODE="$(dlg_capture --title "Hardware clock (RTC)" \
    --menu "How should the hardware clock be stored?\n\nChoose 'local' if you dual-boot Windows (avoids touching the Windows registry)." \
    0 "$BOX_W" 0 \
    utc   "UTC (Linux default, recommended for Linux-only machines)" \
    local "Local time (Windows-compatible, for dual-boot)")" || abort

# ---------------- WAKE-ON-LAN (WOL) ----------------

ENABLE_WOL="no"
WOL_IFACE=""
WOL_NOTE=""

if ask_yes "Wake-on-LAN" "Enable Wake-on-LAN (WOL)?\n\nThe wired network interface is detected automatically; 'ethtool' and a small systemd service are set up so the machine can be woken by a magic packet." no; then
    WOL_CANDIDATES=()
    for ifc in /sys/class/net/*; do
        name="$(basename "$ifc")"
        [[ "$name" == "lo" ]] && continue
        [[ -d "$ifc/wireless" ]] && continue
        WOL_CANDIDATES+=("$name")
    done

    case "${#WOL_CANDIDATES[@]}" in
        0)
            msg_box "Wake-on-LAN" "No wired network interface detected -- Wake-on-LAN will be skipped."
            ;;
        1)
            WOL_IFACE="${WOL_CANDIDATES[0]}"
            ;;
        *)
            WOL_ITEMS=()
            for c in "${WOL_CANDIDATES[@]}"; do
                WOL_ITEMS+=("$c" "$(cat "/sys/class/net/$c/address" 2>/dev/null || true)")
            done
            WOL_IFACE="$(dlg_capture --title "Wake-on-LAN" \
                --menu "Several wired interfaces found. Enable WOL on which one?" \
                0 "$BOX_W" 0 "${WOL_ITEMS[@]}")" || WOL_IFACE=""
            ;;
    esac

    if [[ -n "$WOL_IFACE" ]]; then
        ENABLE_WOL="yes"
        if command -v ethtool >/dev/null 2>&1; then
            wol_caps="$(ethtool "$WOL_IFACE" 2>/dev/null | sed -n 's/.*Supports Wake-on:[[:space:]]*//p' || true)"
            if [[ "$wol_caps" == *g* ]]; then
                WOL_NOTE=" (reports magic-packet support)"
            else
                WOL_NOTE=" (does not report 'g' support -- may still work)"
            fi
        fi
    fi
fi

# ---------------- WI-FI CARRY-OVER (iwd -> NetworkManager) ----------------

IWD_DIR="/var/lib/iwd"
WIFI_CARRY="no"
WIFI_PSK_FILES=()

iwd_ssid_from_file() {
    local name
    name="$(basename "$1" .psk)"
    if [[ "$name" == =* ]]; then
        local hex="${name#=}" out="" i
        for ((i = 0; i < ${#hex}; i += 2)); do
            out+="$(printf "\\x${hex:i:2}")"
        done
        printf '%s' "$out"
    else
        printf '%s' "$name"
    fi
}

if [[ -d "$IWD_DIR" ]]; then
    shopt -s nullglob
    WIFI_PSK_FILES=("$IWD_DIR"/*.psk)
    shopt -u nullglob
fi

if [[ "${#WIFI_PSK_FILES[@]}" -gt 0 ]]; then
    WIFI_NAMES=()
    for f in "${WIFI_PSK_FILES[@]}"; do
        WIFI_NAMES+=("$(iwd_ssid_from_file "$f")")
    done
    if ask_yes "Wi-Fi" "Saved Wi-Fi network(s) on this live system:\n  ${WIFI_NAMES[*]}\n\nCopy them to the installed system so it is online after the first reboot?" yes; then
        WIFI_CARRY="yes"
    fi
fi

# ---------------- DESKTOP ENVIRONMENT ----------------
#
# SINGLE menu (as requested): the first item is "None", the other three are
# the DEs. If "None" is chosen, no DE is installed by archInstall.sh -- you
# can still install one later with installDE.sh.

DE_CHOICE=""      # "", 1 = GNOME, 2 = KDE Plasma, 3 = XFCE
DE_MODE=""        # full | minimal
DE_LABEL="none (CLI only)"

if [[ -n "$NEW_USERNAME" ]]; then
    DE_CHOICE="$(dlg_capture --title "Desktop environment" --default-item 0 \
        --menu "Install a desktop environment now?\n\nIt is installed as the last step; if it fails the base system stays intact and you can run installDE.sh after reboot." \
        0 "$BOX_W" 0 \
        0 "None -- CLI only (install later with installDE.sh)" \
        1 "GNOME (Wayland)" \
        2 "KDE Plasma (Wayland)" \
        3 "XFCE (X11)")" || abort
    if [[ "$DE_CHOICE" == "0" ]]; then
        DE_CHOICE=""
    else
        DE_MODE="$(dlg_capture --title "Package set" \
            --menu "Full or minimal package set?" 0 "$BOX_W" 0 \
            full    "Full -- complete desktop with its usual applications" \
            minimal "Minimal -- just the desktop and the essentials")" || abort
        case "$DE_CHOICE" in
            1) DE_LABEL="GNOME ($DE_MODE)" ;;
            2) DE_LABEL="KDE Plasma ($DE_MODE)" ;;
            3) DE_LABEL="XFCE ($DE_MODE)" ;;
        esac
    fi
fi

# ---------------- SUMMARY + WIPE CONFIRMATION ----------------

if [[ -n "$NEW_USERNAME" ]]; then
    USER_LINE="$NEW_USERNAME ($([[ "$MAKE_SUDO" == "yes" ]] && echo "superuser/sudo" || echo "no sudo"))"
else
    USER_LINE="(none -- only root)"
fi
ROOT_LINE="$([[ "$SET_ROOT_PASSWORD" == "yes" ]] && echo "password set" || echo "locked (use sudo)")"
WOL_LINE="$([[ "$ENABLE_WOL" == "yes" ]] && echo "enabled on ${WOL_IFACE}${WOL_NOTE}" || echo "no")"
WIFI_LINE="$([[ "$WIFI_CARRY" == "yes" ]] && echo "carry over ${WIFI_NAMES[*]}" || echo "no")"

SUMMARY_FILE="$(mktemp)"
cat > "$SUMMARY_FILE" <<SUMMARY_EOF
  THIS WILL DESTROY ALL DATA ON: $DEVICE

$(lsblk -l -o NAME,SIZE,FSTYPE,LABEL "$DEVICE")

  Planned layout:
    ${ESP}       ESP (FAT32, $ESP_SIZE)      -> /efi
    ${BOOTPART}  ext4 ($BOOT_SIZE)           -> /boot
    ${LUKSPART}  LUKS2 -> Btrfs (@  @home  @snapshots)

  Hostname:       $NEW_HOSTNAME
  Timezone:       $TIMEZONE
  Locale:         $LOCALE  (generated: $LOCALES_STR)
  Keymap:         $KEYMAP
  Btrfs options:  $MOUNT_OPTS
  Microcode:      ${UCODE_PKG:-none detected}
  Hardware clock: $RTC_MODE
  User:           $USER_LINE
  Root account:   $ROOT_LINE
  Wake-on-LAN:    $WOL_LINE
  Wi-Fi:          $WIFI_LINE
  Desktop:        $DE_LABEL

  (scroll with the arrow keys / PgUp / PgDn)
SUMMARY_EOF

dlg --title "Summary -- review before the disk is wiped" \
    --exit-label "Continue" --textbox "$SUMMARY_FILE" "$LOG_H" "$LOG_W"
rm -f "$SUMMARY_FILE"

ask_text CONFIRM "FINAL CONFIRMATION" "This is the point of no return.\n\n$DEVICE will be completely erased.\n\nType WIPE (all caps) to continue:" "" || abort
[[ "$CONFIRM" == "WIPE" ]] || abort "Cancelled -- nothing was changed."

# ============================================================
# INSTALL (unattended; live progress in a dialog --gauge)
#
# Everything below runs inside run_install(). NOTE: the body is
# deliberately not indented -- the heredocs inside must keep their
# terminators in column 0.
#
# run_with_gauge gives the function FD 3 pointing at the gauge; stdout
# is redirected inside run_install to $LOG_FILE so that pacman's output
# and our own log/info/warn lines are captured cleanly. Only
# gauge_msg writes the percent+message+phase frames to FD 3.
# ============================================================

DE_FAILED_FILE="$(mktemp)"

run_install() {

# Save the pipe to dialog --gauge as FD 3; redirect stdout to the log.
exec 3>&1
exec 1>>"$LOG_FILE"

# ---- Phase tree shown inside the gauge prompt ----
local -a PHASES=(
    "User info collected"
    "Disk partitioned"
    "Encryption & filesystems"
    "Base system install (pacstrap)"
    "System configured (chroot)"
    "Desktop environment"
    "Finalizing"
)
local CURRENT_PHASE=0
local -a CUR_ITEMS=()
local CUR_IDX=0
local WIN=5

_phase_prompt() {
    local i j n start end out=""
    for ((i=0; i<${#PHASES[@]}; i++)); do
        # Draw the "progress marker" line just before the currently
        # running phase. Everything ABOVE the line is done; the current
        # phase (with its sub-items) and everything BELOW the line still
        # has work to do. Skipped when there is no completed phase yet
        # (would put a stray line at the very top).
        if (( i == CURRENT_PHASE && CURRENT_PHASE > 0 )); then
            out+="$(printf '%*s' $(( BOX_W - 8 )) '' | tr ' ' '-')"$'\n'
        fi

        if (( i < CURRENT_PHASE )); then
            out+="  [✓] ${PHASES[i]}"$'\n'
        elif (( i == CURRENT_PHASE )); then
            out+="  [>] ${PHASES[i]}"$'\n'
            n=${#CUR_ITEMS[@]}
            if (( n > 0 )); then
                start=$(( CUR_IDX - WIN/2 ))
                (( start < 0 )) && start=0
                end=$(( start + WIN ))
                (( end > n )) && end=$n
                (( start > 0 )) && out+="        ..."$'\n'
                for ((j=start; j<end; j++)); do
                    if (( j < CUR_IDX )); then
                        out+="        [x] ${CUR_ITEMS[j]}"$'\n'
                    elif (( j == CUR_IDX )); then
                        out+="        [>] ${CUR_ITEMS[j]}"$'\n'
                    else
                        out+="        [ ] ${CUR_ITEMS[j]}"$'\n'
                    fi
                done
                (( end < n )) && out+="        ..."$'\n'
            fi
        else
            out+="  [ ] ${PHASES[i]}"$'\n'
        fi
    done
    printf '%s' "$out"
}

gauge_msg() {
    local pct="$1" msg="$2"
    {
        printf 'XXX\n%d\n' "$pct"
        _phase_prompt
        printf '\n%s\n' "$msg"
        printf 'XXX\n'
    } >&3
}

set_phase()  { CURRENT_PHASE="$1"; }
set_items()  { CUR_ITEMS=("$@"); CUR_IDX=0; }
advance()    { CUR_IDX=$((CUR_IDX + 1)); }

# ---------------- PARTITIONING ----------------

set_phase 1
set_items "Wiping disk signatures" "Creating partitions" "Re-reading partition table"

gauge_msg 2 "Wiping filesystem signatures on $DEVICE..."
log "Wiping and partitioning $DEVICE..."
wipefs -af "$DEVICE"
advance

gauge_msg 4 "Creating partitions on $DEVICE..."
sgdisk --zap-all "$DEVICE"
sgdisk -n1:0:+${ESP_SIZE} -t1:ef00 -c1:"EFI" "$DEVICE"
sgdisk -n2:0:+${BOOT_SIZE} -t2:8300 -c2:"boot" "$DEVICE"
sgdisk -n3:0:0 -t3:8309 -c3:"cryptroot" "$DEVICE"
advance

gauge_msg 6 "Re-reading partition table..."
partprobe "$DEVICE"
udevadm settle
sleep 3
for p in "$ESP" "$BOOTPART" "$LUKSPART"; do
    [[ -b "$p" ]] || die "$p does not exist yet -- the kernel may not have re-read the partition table. Try running 'partprobe $DEVICE' manually, then re-run this script."
done
advance

# ---------------- FORMAT + LUKS + BTRFS ----------------

set_phase 2
set_items \
    "Formatting ESP and /boot" \
    "Creating and opening LUKS2" \
    "Creating Btrfs and subvolumes" \
    "Mounting filesystems" \
    "Optimizing mirrorlist"

gauge_msg 9 "Formatting ESP and /boot..."
log "Formatting ESP and /boot..."
mkfs.fat -F32 -n EFI "$ESP"
mkfs.ext4 -F -L boot "$BOOTPART"
sync
udevadm settle
advance

gauge_msg 11 "Creating LUKS2 container on $LUKSPART..."
log "Creating LUKS2 container on $LUKSPART..."
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --label cryptroot --batch-mode --key-file=- "$LUKSPART"

gauge_msg 13 "Opening LUKS2 container..."
log "Opening LUKS2 container..."
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$LUKSPART" cryptroot
LUKS_UUID="$(cryptsetup luksUUID "$LUKSPART")"
info "LUKS UUID: $LUKS_UUID"
advance

gauge_msg 15 "Creating Btrfs filesystem and subvolumes..."
log "Creating Btrfs filesystem and subvolumes..."
mkfs.btrfs -L cryptroot /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt
advance

gauge_msg 17 "Mounting filesystems..."
log "Mounting filesystems..."
mount -o "${MOUNT_OPTS},subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,boot,efi}
mount -o "${MOUNT_OPTS},subvol=@home" /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount "$BOOTPART" /mnt/boot
mount "$ESP" /mnt/efi
advance

gauge_msg 19 "Optimizing pacman mirrorlist with reflector..."
log "Optimizing pacman mirrorlist with reflector..."
REFLECTOR_AVAILABLE=1
if ! command -v reflector >/dev/null 2>&1; then
    pacman -S --needed --noconfirm reflector || REFLECTOR_AVAILABLE=0
fi
if [[ "$REFLECTOR_AVAILABLE" -eq 1 ]]; then
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak 2>/dev/null || true
    if reflector --latest 20 --protocol https --age 12 --sort rate --save /etc/pacman.d/mirrorlist; then
        info "Mirrorlist updated with the fastest HTTPS mirrors."
    else
        warn "reflector failed -- restoring the original mirrorlist and continuing with it."
        cp /etc/pacman.d/mirrorlist.bak /etc/pacman.d/mirrorlist 2>/dev/null || true
    fi
else
    warn "Could not install reflector -- continuing with the default mirrorlist."
fi
advance

# ---------------- PACSTRAP ----------------

set_phase 3
set_items "Downloading packages" "Installing packages"

gauge_msg 21 "Installing base system (pacstrap) -- downloading, this may take a while..."
log "Installing base system (pacstrap)..."

PACKAGES=(base base-devel linux linux-firmware btrfs-progs cryptsetup
          grub efibootmgr sudo networkmanager wpa_supplicant vim git
          zram-generator dialog)
[[ -n "$UCODE_PKG" ]] && PACKAGES+=("$UCODE_PKG")
[[ "$ENABLE_WOL" == "yes" ]] && PACKAGES+=(ethtool)

# Use a FIFO (not a pipe) so the while-loop runs in the CURRENT shell --
# a normal `pacstrap ... | while read` puts the loop in a subshell and
# any CUR_IDX/CUR_ITEMS updates inside it would be lost. stdbuf -oL
# forces line buffering so the gauge updates smoothly.
_ps_fifo="$(mktemp -u)"
mkfifo "$_ps_fifo"
stdbuf -oL pacstrap -K /mnt "${PACKAGES[@]}" > "$_ps_fifo" 2>&1 &
_ps_pid=$!

_first_nm=0
while IFS= read -r line; do
    printf '%s\n' "$line"
    if [[ "$line" =~ ^\(([0-9]+)/([0-9]+)\)[[:space:]]+installing ]]; then
        _cur="${BASH_REMATCH[1]}"
        _tot="${BASH_REMATCH[2]}"
        if (( _first_nm == 0 )); then
            _first_nm=1
            CUR_IDX=1
        fi
        gauge_msg "$(( 21 + 22 * _cur / _tot ))" "Installing base packages (${_cur}/${_tot})..."
    fi
done < "$_ps_fifo"

PACSTRAP_RC=0
wait "$_ps_pid" || PACSTRAP_RC=$?
rm -f "$_ps_fifo"
[[ "$PACSTRAP_RC" -eq 0 ]] || die "pacstrap failed (exit code $PACSTRAP_RC) -- see $LOG_FILE"
advance

gauge_msg 45 "Generating /etc/fstab..."
log "/etc/fstab:"
genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab

# ---------------- WI-FI CARRY-OVER: WRITE NM PROFILES ----------------

if [[ "$WIFI_CARRY" == "yes" ]]; then
    gauge_msg 47 "Copying saved Wi-Fi network(s) to NetworkManager..."
    log "Copying saved Wi-Fi network(s) to NetworkManager..."
    NM_CONN_DIR="/mnt/etc/NetworkManager/system-connections"
    mkdir -p "$NM_CONN_DIR"
    wifi_idx=0
    for f in "${WIFI_PSK_FILES[@]}"; do
        ssid="$(iwd_ssid_from_file "$f")"
        psk="$(sed -n 's/^Passphrase=//p' "$f" | head -n1)"
        [[ -n "$psk" ]] || psk="$(sed -n 's/^PreSharedKey=//p' "$f" | head -n1)"
        if [[ -z "$ssid" || -z "$psk" ]]; then
            warn "Could not read credentials for '$ssid' -- skipping (use 'nmtui' after reboot)."
            continue
        fi
        if [[ "$ssid" == *\;* ]]; then
            warn "SSID '$ssid' contains ';' which NetworkManager keyfiles can't store reliably -- skipping (use 'nmtui' after reboot)."
            continue
        fi
        wifi_idx=$((wifi_idx + 1))
        safe="$(printf '%s' "$ssid" | tr -c 'A-Za-z0-9._-' '_')"
        out="${NM_CONN_DIR}/wifi-${wifi_idx}-${safe}.nmconnection"
        ssid_esc="${ssid//\\/\\\\}"
        psk_esc="${psk//\\/\\\\}"
        (
            umask 077
            cat > "$out" <<NM_EOF
[connection]
id=${ssid_esc}
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${ssid_esc}

[wifi-security]
key-mgmt=wpa-psk
psk=${psk_esc}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
NM_EOF
        )
        chmod 600 "$out"
        info "Saved profile for '$ssid'."
    done
    [[ "$wifi_idx" -gt 0 ]] || WIFI_CARRY="no"
fi

# ---------------- USER ACCOUNT + PASSWORDS ----------------

gauge_msg 49 "Creating user account and setting passwords..."

if [[ -n "${NEW_USERNAME}" ]]; then
    log "Creating user ${NEW_USERNAME}..."
    if [[ "${MAKE_SUDO}" == "yes" ]]; then
        arch-chroot /mnt useradd -m -G wheel -s /bin/bash "${NEW_USERNAME}"
        install -d -m 750 /mnt/etc/sudoers.d
        printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
        chmod 440 /mnt/etc/sudoers.d/10-wheel
        if ! arch-chroot /mnt visudo -c >/dev/null; then
            rm -f /mnt/etc/sudoers.d/10-wheel
            die "sudoers validation failed -- root is locked, so the system would be unusable. Aborting."
        fi
    else
        arch-chroot /mnt useradd -m -s /bin/bash "${NEW_USERNAME}"
    fi
    printf '%s:%s\n' "$NEW_USERNAME" "$USER_PASS" | arch-chroot /mnt chpasswd
    info "Password set for ${NEW_USERNAME}."
fi

if [[ "$SET_ROOT_PASSWORD" == "yes" ]]; then
    printf 'root:%s\n' "$ROOT_PASS" | arch-chroot /mnt chpasswd
    info "Root password set."
else
    arch-chroot /mnt passwd -l root
    info "Root account locked -- use sudo."
fi

# ---------------- CHROOT CONFIGURATION (unattended) ----------------

set_phase 4
set_items \
    "Hostname, timezone, locales" \
    "Network and system services" \
    "Initramfs (mkinitcpio)" \
    "Bootloader (GRUB)"

gauge_msg 52 "Configuring hostname, timezone, locales..."
log "Configuring the new system (chroot)..."

# Split the (already validated) KEYMAP list. Both /etc/vconsole.conf at
# runtime (KEYMAP= / KEYMAP_TOGGLE=) and sd-vconsole in the initramfs
# (rd.vconsole.keymap= / rd.vconsole.keymap_toggle=) accept ONE keymap per
# parameter -- a comma-separated list makes them try to "loadkeys us,croat"
# and fail with "Failed to start Virtual Console Setup". The two values
# are expanded by THIS (outer) shell inside the unquoted chroot heredoc,
# so no \$ escaping is needed.
IFS=, read -r -a _km_arr <<< "$KEYMAP"
KEYMAP_PRIMARY="${_km_arr[0]}"
KEYMAP_TOGGLE="${_km_arr[1]:-}"

# The GRUB kernel cmdline receives the two keymaps as SEPARATE parameters,
# exactly like /etc/vconsole.conf does. Comma-separated would break
# sd-vconsole in the initramfs.
VCONSOLE_CMDLINE="rd.vconsole.keymap=${KEYMAP_PRIMARY}"
[[ -z "$KEYMAP_TOGGLE" ]] || VCONSOLE_CMDLINE+=" rd.vconsole.keymap_toggle=${KEYMAP_TOGGLE}"

# --- CHROOT SCRIPT ---
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -Eeuo pipefail

echo "$NEW_HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

# Some VMs have no RTC -- not worth aborting a finished install for.
if [[ "$RTC_MODE" == "local" ]]; then
    hwclock --systohc --localtime || echo "WARNING: could not write the hardware clock" >&2
else
    hwclock --systohc --utc || echo "WARNING: could not write the hardware clock" >&2
fi

# Enable every locale from LOCALES (\$-escaped variables are expanded
# inside the chroot, the unescaped list is expanded by the installer).
for _l in $LOCALES_STR; do
    _cs="\${_l##*.}"
    sed -i "s/^#\${_l} \${_cs}/\${_l} \${_cs}/" /etc/locale.gen
    grep -q "^\${_l} \${_cs}" /etc/locale.gen || echo "\${_l} \${_cs}" >> /etc/locale.gen
done

locale-gen

echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP_PRIMARY}" > /etc/vconsole.conf
if [[ -n "${KEYMAP_TOGGLE}" ]]; then
    echo "KEYMAP_TOGGLE=${KEYMAP_TOGGLE}" >> /etc/vconsole.conf
fi

mkdir -p /etc/profile.d
echo "export LANGUAGE=${LOCALE%%.*}:${LOCALE%%_*}" > /etc/profile.d/locale.sh
chmod 644 /etc/profile.d/locale.sh

cat >> /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.0.1   ${NEW_HOSTNAME}.localdomain ${NEW_HOSTNAME}
HOSTS_EOF

CHROOT_EOF
advance

gauge_msg 60 "Configuring network and system services..."
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -Eeuo pipefail

systemctl enable NetworkManager

if [[ "$ENABLE_WOL" == "yes" ]]; then
    cat > /etc/systemd/system/wol@.service <<'WOL_EOF'
[Unit]
Description=Wake-on-LAN for %i
Requires=network.target
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ethtool -s %i wol g

[Install]
WantedBy=multi-user.target
WOL_EOF
    systemctl enable "wol@${WOL_IFACE}.service"
fi

cat > /etc/systemd/zram-generator.conf <<'ZRAM_EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM_EOF

CHROOT_EOF
advance

gauge_msg 68 "Rebuilding initramfs..."
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -Eeuo pipefail

sed -i -E '/^[[:space:]]*HOOKS=/d' /etc/mkinitcpio.conf
cat >> /etc/mkinitcpio.conf <<'HOOKS_EOF'

HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
HOOKS_EOF
mkinitcpio -P

CHROOT_EOF
advance

gauge_msg 74 "Installing GRUB for UEFI..."
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -Eeuo pipefail

sed -i -E "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${LUKS_UUID}=cryptroot root=\/dev\/mapper\/cryptroot rootflags=subvol=@ quiet ${VCONSOLE_CMDLINE} rd.locale.LANG=${LOCALE}\"/" /etc/default/grub

grub-install --target=${GRUB_TARGET} --efi-directory=/efi --boot-directory=/boot --bootloader-id=GRUB --recheck --removable
grub-mkconfig -o /boot/grub/grub.cfg

if ! grep -q '^menuentry' /boot/grub/grub.cfg; then
    echo "==> WARNING: /boot/grub/grub.cfg has no menuentry -- GRUB will likely drop to a rescue shell on boot." >&2
fi

CHROOT_EOF
advance

# ---------------- DESKTOP ENVIRONMENT (optional, non-fatal) ----------------

if [[ -n "$DE_CHOICE" ]]; then
    set_phase 5
    set_items "Downloading DE packages" "Installing DE packages"

    gauge_msg 80 "Installing desktop environment: $DE_LABEL ..."
    log "Installing the desktop environment: $DE_LABEL ..."

    DE_SCRIPT="$SCRIPT_DIR/installDE.sh"
    DE_DL=""
    if [[ ! -f "$DE_SCRIPT" ]]; then
        DE_DL="$(mktemp)"
        if fetch_repo_file installDE.sh "$DE_DL"; then
            DE_SCRIPT="$DE_DL"
        else
            DE_SCRIPT=""
            warn "Could not download installDE.sh."
        fi
    fi

    DE_OK=0
    if [[ -n "$DE_SCRIPT" ]]; then
        mkdir -p /mnt/root/arch-setup-tmp
        install -m 755 "$DE_SCRIPT" /mnt/root/arch-setup-tmp/installDE.sh
        install -m 644 "$SCRIPT_DIR/lib.sh" /mnt/root/arch-setup-tmp/lib.sh

        # Same FIFO trick as pacstrap: the loop must run in the current
        # shell so CUR_IDX updates persist across iterations.
        _de_fifo="$(mktemp -u)"
        mkfifo "$_de_fifo"
        arch-chroot /mnt env DE_CHOICE="$DE_CHOICE" INSTALL_MODE="$DE_MODE" \
                TARGET_USER="$NEW_USERNAME" ASSUME_YES=1 INSTALL_IN_CHROOT=1 \
                /root/arch-setup-tmp/installDE.sh > "$_de_fifo" 2>&1 &
        _de_pid=$!

        _first_de_nm=0
        while IFS= read -r line; do
            printf '%s\n' "$line"
            if [[ "$line" =~ ^\(([0-9]+)/([0-9]+)\)[[:space:]]+installing ]]; then
                _cur="${BASH_REMATCH[1]}"
                _tot="${BASH_REMATCH[2]}"
                if (( _first_de_nm == 0 )); then
                    _first_de_nm=1
                    CUR_IDX=1
                fi
                gauge_msg "$(( 80 + 17 * _cur / _tot ))" "Installing desktop environment (${_cur}/${_tot})..."
            fi
        done < "$_de_fifo"

        DE_RC=0
        wait "$_de_pid" || DE_RC=$?
        rm -f "$_de_fifo"
        [[ "$DE_RC" -eq 0 ]] && DE_OK=1

        rm -rf /mnt/root/arch-setup-tmp

        # --- Safety net ---
        #
        # installDE.sh just tried to enable the display manager and set
        # graphical.target as the default, but a fresh chroot can end up
        # without the necessary symlinks even when systemctl reports
        # success. Without them the system boots to a TTY login prompt
        # instead of the graphical login. This re-creates the two
        # symlinks directly inside the chroot, using chroot-relative
        # paths so they resolve correctly once the system boots.
        if [[ "$DE_OK" -eq 1 ]]; then
            case "$DE_CHOICE" in
                1) _dm="gdm.service" ;;
                2) _dm="sddm.service" ;;
                3) _dm="lightdm.service" ;;
                *) _dm="" ;;
            esac
            if [[ -n "$_dm" ]]; then
                arch-chroot /mnt /bin/bash <<DM_FIX_EOF >>"$LOG_FILE" 2>&1
set -Eeuo pipefail
DM_UNIT="/usr/lib/systemd/system/${_dm}"
DM_LINK="/etc/systemd/system/display-manager.service"
DEFAULT_LINK="/etc/systemd/system/default.target"
DEFAULT_TARGET="/usr/lib/systemd/system/graphical.target"

if [[ -f "\$DM_UNIT" && ! -e "\$DM_LINK" ]]; then
    ln -sf "\$DM_UNIT" "\$DM_LINK"
    echo "safety net: created \$DM_LINK -> \$DM_UNIT"
fi
if [[ -f "\$DEFAULT_TARGET" ]]; then
    if [[ ! -L "\$DEFAULT_LINK" || "\$(readlink -f "\$DEFAULT_LINK" 2>/dev/null)" != "\$DEFAULT_TARGET" ]]; then
        ln -sf "\$DEFAULT_TARGET" "\$DEFAULT_LINK"
        echo "safety net: set \$DEFAULT_LINK -> \$DEFAULT_TARGET"
    fi
fi
DM_FIX_EOF
                info "Verified display-manager and graphical.target setup."
            fi
        fi
    fi
    [[ -z "$DE_DL" ]] || rm -f "$DE_DL"

    if [[ "$DE_OK" -eq 1 ]]; then
        info "Desktop environment installed."
    else
        echo "failed" > "$DE_FAILED_FILE"
        warn "Desktop environment install failed -- the base system is fine. After reboot run installDE.sh again."
    fi
    advance
fi

# ---------------- COPY INSTALLER SCRIPTS TO THE NEW SYSTEM ----------------

set_phase 6
set_items "Copying installer scripts"

gauge_msg 98 "Copying installer scripts to /archInstall on the new system..."
log "Copying the installer scripts to /archInstall on the new system..."
mkdir -p /mnt/archInstall/scripts

MANAGER_SCRIPT=""
for candidate in "${ARCH_MANAGER_PATH:-}" "$SCRIPT_DIR/../arch-manager.sh" "$SCRIPT_DIR/arch-manager.sh" "./arch-manager.sh"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        MANAGER_SCRIPT="$candidate"
        break
    fi
done

if [[ -n "$MANAGER_SCRIPT" ]]; then
    cp "$MANAGER_SCRIPT" /mnt/archInstall/arch-manager.sh
elif fetch_repo_file arch-manager.sh /mnt/archInstall/arch-manager.sh; then
    info "arch-manager.sh downloaded from the repository."
else
    warn "arch-manager.sh not found and could not be downloaded. After reboot: sudo curl -o /archInstall/arch-manager.sh ${REPO_RAW_URL}/arch-manager.sh"
fi

cp -f "$SCRIPT_DIR"/*.sh /mnt/archInstall/scripts/ 2>/dev/null || true
cp -f "$SCRIPT_DIR/lib.sh" /mnt/archInstall/lib.sh
for s in lib.sh setupAfterInstall.sh installDE.sh installApps.sh; do
    if [[ ! -f "/mnt/archInstall/scripts/$s" ]]; then
        fetch_repo_file "$s" "/mnt/archInstall/scripts/$s" || warn "Could not fetch $s for /archInstall/scripts."
    fi
done
chmod +x /mnt/archInstall/*.sh /mnt/archInstall/scripts/*.sh 2>/dev/null || true

cp -f "$LOG_FILE" /mnt/root/archInstall.log 2>/dev/null || true
log "Base install complete."
advance

gauge_msg 100 "Installation complete."

exec 1>&3
exec 3>&-
}

# Taller gauge so the phase tree + sub-steps fit comfortably.
GAUGE_HEIGHT=22

run_with_gauge "Installing Arch Linux" "$LOG_FILE" run_install

# Passwords are no longer needed in memory.
unset LUKS_PASS USER_PASS ROOT_PASS

if [[ "$RUN_GAUGE_RC" -ne 0 ]]; then
    msg_box "Installation FAILED" "The installation did not finish.\n\nDo NOT reboot into this system. See the log for details:\n  $LOG_FILE\n\nFix the problem and run the installer again."
    exit 1
fi

# ---------------- DONE ----------------

DONE_TEXT="Arch Linux was installed successfully."
if [[ -s "$DE_FAILED_FILE" ]]; then
    DONE_TEXT+="\n\nNOTE: the desktop environment install FAILED. The base system is fine -- after reboot run installDE.sh again."
elif [[ -n "$DE_CHOICE" ]]; then
    DONE_TEXT+="\n\nDesktop: $DE_LABEL (login screen appears after reboot)."
fi
if [[ "$WIFI_CARRY" != "yes" ]]; then
    DONE_TEXT+="\n\nNo Wi-Fi network was carried over. If you have no Ethernet, run 'nmtui' after reboot to connect."
fi
DONE_TEXT+="\n\nAfter reboot, log in and run:\n  sudo /archInstall/arch-manager.sh\nto continue with Snapper/GRUB setup (option 2) and applications."
rm -f "$DE_FAILED_FILE"

msg_box "Done" "$DONE_TEXT"

if ask_yes "Reboot" "Unmount everything and reboot now?\n\n(Remove the install media when the screen goes black.)" yes; then
    clear
    if umount -R /mnt && cryptsetup close cryptroot; then
        reboot
    else
        echo "Could not unmount cleanly. Run: umount -R /mnt; cryptsetup close cryptroot; reboot"
    fi
else
    clear
    echo "Not rebooting. When ready: umount -R /mnt && cryptsetup close cryptroot && reboot"
fi
