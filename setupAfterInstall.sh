#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: LUKS2 + Btrfs + Snapper + GRUB + Plymouth
#
# Run AFTER the normal Arch installation, as root.
#
# Expected filesystem layout:
#
#   /efi         unencrypted EFI System Partition
#   /boot        unencrypted boot filesystem
#
#   LUKS2
#     └── Btrfs
#          ├── @             -> /
#          ├── @home        -> /home
#          └── @snapshots   -> /.snapshots
#
# IMPORTANT:
#   - This script does NOT partition disks.
#   - This script does NOT format anything.
#   - This script does NOT create/modify LUKS.
#   - /home is intentionally NOT managed by Snapper.
#
# Boot stack:
#   UEFI -> GRUB -> kernel + mkinitcpio
#   -> systemd initramfs -> Plymouth -> sd-encrypt -> LUKS2
#
# Plymouth theme:
#   https://github.com/sveto8/archInstall/tree/main/plymouth-themes
#   Themes are downloaded as .tar.xz archives from that repo.
# ============================================================

# ---------------- CONFIGURATION ----------------

SNAPPER_CONFIG="root"

# Snapper retention
NUMBER_LIMIT="20"
NUMBER_LIMIT_IMPORTANT="10"
MIN_AGE="1800"

TIMELINE_LIMIT_HOURLY="0"
TIMELINE_LIMIT_DAILY="20"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_YEARLY="0"

# Btrfs space protection
SPACE_LIMIT="0.30"
FREE_LIMIT="0.20"

# Btrfs quota (qgroups) is required for Snapper's SPACE_LIMIT/FREE_LIMIT
# cleanup to work, but it adds real overhead on balance/scrub and on
# systems with many subvolumes/snapshots. Set to "no" to skip it and
# rely purely on NUMBER_LIMIT / TIMELINE_LIMIT_* for cleanup.
ENABLE_BTRFS_QUOTA="yes"

# Enable OS prober so GRUB detects other operating systems (e.g. Windows
# on a dual-boot machine) and lists them in the boot menu. On Arch this
# requires the "os-prober" package plus ntfs-3g and fuse3 (os-prober
# uses grub-mount, which relies on FUSE3 and needs NTFS support to read
# the Windows partition). GRUB also needs GRUB_DISABLE_OS_PROBER=false
# in /etc/default/grub -- both are handled automatically below.
#
# With "yes" you are asked how rigorous the scan should be: only Windows/
# Linux on INTERNAL disks (default; USB sticks, external drives and
# optical media are skipped), everything os-prober finds, or none.
ENABLE_OS_PROBER="yes"

# Fallback lists of the theme archives in the repo (names of the .tar.xz
# files without extension). They are used ONLY when the repo folder can't be
# listed (offline, GitHub API rate limit); normally the menus are built from
# what really is in grub-themes/ and plymouth-themes/ on GitHub, so adding a
# theme to the repo is all it takes -- no script edit.
PLYMOUTH_THEMES=(
    "cuts_alt"
    "hud_3"
    "linux-penguin"
    "metal_ball"
)

# UEFI boot entry name. This is what shows up in the firmware's boot menu
# (F11/F12). The script also removes any old "GRUB" or "UEFI OS" entries
# left behind by archInstall.sh so the firmware menu only shows one
# Arch entry -- but ONLY entries that live on this same ESP, so boot
# entries from other Linux installations on other disks are untouched.
GRUB_BOOTLOADER_ID="Arch Linux"

# Path to the GRUB defaults file. It's edited in place by set_grub_option()
# throughout the script -- defined here so that every section (including
# the GRUB theme install step, which runs before the GRUB config section)
# can safely reference it.
GRUB_DEFAULT_FILE="/etc/default/grub"

GRUB_THEMES=(
    "Xenlism-Arch"
    "arch-linux"
    "poly-dark"
)

# Some GRUB versions (2.12+) auto-add a menuentry for every UEFI "Boot####"
# variable in NVRAM -- "UiApp", "UEFI VBOX CD-ROM", "UEFI VBOX HARDDISK",
# "PXE", and even our own "GRUB" / "Arch Linux" entries. These are pure
# clutter (you never want to boot the firmware's boot list from the boot
# menu) and are stripped out of /boot/grub/grub.cfg right after it is
# generated. The plain "UEFI Firmware Settings" entry is NOT affected --
# it has a different title.
STRIP_EFI_BOOTNEXT_ENTRIES="yes"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_url="${ARCH_REPO_URL:-https://raw.githubusercontent.com/sveto8/archInstall/main}"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    # Download to a temporary file FIRST (never write a partial file
    # directly next to the script -- the folder may be a read-only or
    # permission-quirky mount). Verify the download produced a non-empty
    # file, then move it into place. If the script folder turns out to be
    # unwritable, fall back to keeping lib.sh in $TMPDIR.
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
        echo "       Put lib.sh in the same folder as this script and run it again." >&2
        exit 1
    fi
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Theme archives live next to the scripts in the same repository.
PLYMOUTH_THEMES_BASE_URL="${REPO_RAW_URL}/plymouth-themes"
GRUB_THEMES_BASE_URL="${REPO_RAW_URL}/grub-themes"

BACKTITLE="Arch Linux installer -- Btrfs / Snapper / GRUB"
LOG_FILE="/root/setupAfterInstall.log"

BACKUP_DIR="/root/btrfs-setup-backups/$(date +%Y%m%d-%H%M%S)"
PLYMOUTH_TMP="/tmp/plymouth-theme-$$"
PLYMOUTH_OK=0   # 0 = not installed / failed, 1 = success

cleanup() {
    rm -rf "$PLYMOUTH_TMP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'die "Failed at line $LINENO. Configuration backups (if any were made yet) are in $BACKUP_DIR."' ERR

# ---------------- GRUB OPTION HELPER ----------------
#
# Replace a GRUB option in-place in /etc/default/grub.
#
# The default /etc/default/grub shipped by the grub package contains
# commented-out examples such as:
#
#     #GRUB_SAVEDEFAULT=true
#     #GRUB_DISABLE_OS_PROBER=false
#     #GRUB_THEME="/path/to/gfxtheme"
#
# A naive `grep '^GRUB_X='` check fails to see those commented lines and
# appends a new uncommented entry at the bottom of the file, resulting in
# both the commented example AND the new value being present -- which is
# confusing and can override what the user expects.
#
# This helper matches both "KEY=" and "#KEY=" (with optional leading
# whitespace), uncomments and replaces in place. It only appends to the
# end of the file when the option truly doesn't exist anywhere.
set_grub_option() {
    local key="$1"
    local value="$2"
    local file="$3"
    # Escape what sed treats specially in the replacement: '\', '&' (= the
    # matched text) and the '|' delimiter used below.
    local escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"

    if grep -qE "^#?[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^#?[[:space:]]*${key}=.*|${key}=${escaped_value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# ---------------- OS-PROBER HELPERS ----------------
#
# By default os-prober scans EVERY partition it can see, so USB sticks
# (Arch/Windows installers, rescue sticks), external drives, etc. show up
# as boot menu entries. With OS_PROBER_MODE="internal" we tell GRUB to skip
# filesystems on removable/USB-attached disks via GRUB_OS_PROBER_SKIP_LIST
# (a space-separated list of "<fs UUID>@<device>" -- the form that works on
# both older and newer GRUB). The list lives in /etc/default/grub, so it
# also applies to later automatic grub-mkconfig runs (kernel updates,
# grub-btrfs).

# Prints "UUID@/dev/part" for every filesystem on a removable (RM=1) or
# USB-attached (TRAN=usb) disk, including optical drives.
external_skip_list() {
    local disk rm tran part uuid skip_out=()
    while read -r disk rm tran; do
        [[ "$rm" == "1" || "$tran" == "usb" ]] || continue
        while read -r part uuid; do
            [[ -n "$uuid" ]] && skip_out+=("${uuid}@/dev/${part}")
        done < <(lsblk -rno NAME,UUID "/dev/${disk}" | awk 'NF==2')
    done < <(lsblk -dno NAME,RM,TRAN | awk '{print $1, $2, ($3 == "" ? "-" : $3)}')
    echo "${skip_out[*]:-}"
}

# True if the given partition (/dev/...) sits on a removable/USB disk.
is_external_disk_part() {
    local pk rm tran
    pk="$(lsblk -no PKNAME "$1" 2>/dev/null | head -n1)"
    [[ -n "$pk" ]] || pk="$(basename "$1")"
    read -r rm tran < <(lsblk -dno RM,TRAN "/dev/${pk}" 2>/dev/null | awk '{print $1, ($2 == "" ? "-" : $2)}') || return 1
    [[ "$rm" == "1" || "$tran" == "usb" ]]
}

# ---------------- GRUB: STRIP 'EFI BootNext' ENTRIES ----------------
#
# Newer GRUB versions (2.12+) add a menuentry for every UEFI "Boot####"
# variable in NVRAM, so the menu gets polluted with entries like
# "UEFI Firmware Settings" (kept -- that one is useful), "UiApp",
# "UEFI VBOX CD-ROM", "UEFI VBOX HARDDISK", "PXE", and even our own
# "GRUB" / "Arch Linux" entries. Only the ones whose title ends with
# "(EFI BootNext)" are removed; everything else (including submenu
# wrappers that only contained such entries -- they are simply left
# empty) is preserved.
#
# Implementation: an awk state machine that skips a `menuentry ...
# (EFI BootNext) ... { ... }` block entirely, tracking brace depth so
# that nested { } inside the block don't confuse it.
strip_efi_bootnext_entries() {
    local cfg="/boot/grub/grub.cfg"
    [[ -f "$cfg" ]] || return 0
    grep -q '(EFI BootNext)' "$cfg" 2>/dev/null || return 0

    local tmp
    tmp="$(mktemp)"
    awk '
        /^[[:space:]]*menuentry .*\(EFI BootNext\)/ {
            skip = 1
            depth = 0
            n = gsub(/\{/, "{"); depth += n
            n = gsub(/\}/, "}"); depth -= n
            if (depth <= 0) skip = 0
            next
        }
        skip {
            n = gsub(/\{/, "{"); depth += n
            n = gsub(/\}/, "}"); depth -= n
            if (depth <= 0) skip = 0
            next
        }
        { print }
    ' "$cfg" > "$tmp"
    mv "$tmp" "$cfg"
}

# ---------------- BASIC CHECKS ----------------

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "This script needs root, and sudo isn't installed to elevate automatically. Run it with: su -c ./setupAfterInstall.sh"
    echo "Not running as root -- re-launching with sudo (you may be asked for your password)."
    exec sudo -- "$0" "$@"
fi

command -v pacman >/dev/null || die "pacman not found."
command -v findmnt >/dev/null || die "findmnt not found."
command -v lsblk >/dev/null || die "lsblk not found."

ensure_dialog
ui_init

[[ -d /sys/firmware/efi ]] || die "System was not booted in UEFI mode."

ROOT_FSTYPE="$(findmnt -n -o FSTYPE /)"
[[ "$ROOT_FSTYPE" == "btrfs" ]] || die "Root filesystem is not Btrfs."

findmnt -n /efi >/dev/null 2>&1 || die "/efi is not mounted."
findmnt -n /boot >/dev/null 2>&1 || die "/boot is not mounted."
findmnt -n /.snapshots >/dev/null 2>&1 || die "/.snapshots is not mounted."

# /.snapshots gets unmounted and remounted later during the Snapper
# create-config step. That remount relies on /etc/fstab having a real
# entry for it -- verify that up front instead of discovering it mid-run.
grep -qE '^\S+[[:space:]]+/\.snapshots[[:space:]]' /etc/fstab || \
    die "/etc/fstab has no entry for /.snapshots. Add one (matching your @snapshots subvolume) before running this script."

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
SNAP_SOURCE="$(findmnt -n -o SOURCE /.snapshots)"

info "Root:       $ROOT_SOURCE"
info "Snapshots:  $SNAP_SOURCE"
info "Boot FS:    $(findmnt -n -o FSTYPE /boot)"
info "EFI FS:     $(findmnt -n -o FSTYPE /efi)"

[[ "$ROOT_SOURCE" == *"subvol=@"* || "$ROOT_SOURCE" == *"[/@]"* || "$ROOT_SOURCE" == *"/@"* ]] || \
    warn "Could not prove that / is mounted from the @ subvolume."

[[ "$SNAP_SOURCE" == *"@snapshots"* ]] || \
    warn "Could not prove that /.snapshots is mounted from @snapshots."

if mountpoint -q /home; then
    HOME_SOURCE="$(findmnt -n -o SOURCE /home || true)"
    info "Home:       $HOME_SOURCE"
    [[ "$HOME_SOURCE" == *"@home"* ]] || \
        warn "/home does not appear to be mounted from @home."
else
    warn "/home is not a separate mount. The script will not change it."
fi

# ---------------- FIND LUKS DEVICE ----------------

log "Detecting the LUKS2 device..."

command -v cryptsetup >/dev/null || die "cryptsetup is not installed."

# Walk backwards from the root filesystem to the physical device.
ROOT_BLK="$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')"

LUKS_DEVICE=""
MAPPER_NAME=""

if [[ "$ROOT_BLK" == /dev/mapper/* ]]; then
    MAPPER_NAME="${ROOT_BLK#/dev/mapper/}"
elif [[ "$ROOT_BLK" == /dev/dm-* ]]; then
    MAPPER_NAME="$(lsblk -no NAME "$ROOT_BLK" 2>/dev/null | head -n1)"
fi

# Primary: ask cryptsetup directly for the backing device of this mapping.
# This is more reliable than lsblk's PKNAME column, which some lsblk
# versions fail to populate when queried for a single device path
# instead of the full dependency tree.
if [[ -n "$MAPPER_NAME" ]] && cryptsetup status "$MAPPER_NAME" >/dev/null 2>&1; then
    LUKS_DEVICE="$(cryptsetup status "$MAPPER_NAME" | awk -F': *' '/^[[:space:]]*device:/{print $2}')"
fi

# Fallback: walk the FULL lsblk dependency tree in one call (not a
# per-device query) and read PKNAME straight out of that table.
if [[ -z "$LUKS_DEVICE" || ! -b "$LUKS_DEVICE" ]]; then
    LUKS_DEVICE=""
    while read -r NAME TYPE PKNAME; do
        [[ "$TYPE" == "crypt" ]] || continue
        [[ -z "$MAPPER_NAME" || "$NAME" == "$MAPPER_NAME" ]] || continue
        [[ -n "$PKNAME" ]] || continue
        LUKS_DEVICE="/dev/$PKNAME"
        break
    done < <(lsblk -rno NAME,TYPE,PKNAME)
fi

[[ -n "$LUKS_DEVICE" && -b "$LUKS_DEVICE" ]] || \
    die "Could not determine the LUKS backing device. Try: cryptsetup status ${MAPPER_NAME:-<mapper-name>}"

LUKS_UUID="$(cryptsetup luksUUID "$LUKS_DEVICE")"
ROOT_BTRFS_UUID="$(findmnt -n -o UUID /)"

# Name of the opened LUKS mapping and the subvolume / is mounted from --
# taken from the running system instead of assuming "cryptroot" and "@".
CRYPT_NAME="${MAPPER_NAME:-cryptroot}"
ROOT_SUBVOL="$(findmnt -n -o OPTIONS / | tr ',' '\n' | sed -n 's/^subvol=//p' | head -n1)"
ROOT_SUBVOL="${ROOT_SUBVOL#/}"
[[ -n "$ROOT_SUBVOL" ]] || ROOT_SUBVOL="@"

info "LUKS device: $LUKS_DEVICE"
info "LUKS UUID:   $LUKS_UUID"
info "Btrfs UUID:  $ROOT_BTRFS_UUID"
info "Mapper name: $CRYPT_NAME"
info "Root subvol: $ROOT_SUBVOL"

# ---------------- CPU VENDOR / MICROCODE ----------------

UCODE_PKG=""
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
    UCODE_PKG="amd-ucode"
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
    UCODE_PKG="intel-ucode"
else
    warn "Could not detect CPU vendor; no microcode package will be installed automatically."
fi
info "Microcode:  ${UCODE_PKG:-none detected}"

# ---------------- GRUB THEME ----------------

# Prefer the archives that really are in the repo's grub-themes/ folder.
mapfile -t _remote_themes < <(repo_list_archives grub-themes || true)
if [[ "${#_remote_themes[@]}" -gt 0 ]]; then
    GRUB_THEMES=("${_remote_themes[@]}")
else
    info "Could not list grub-themes/ in the repo -- using the built-in theme list."
fi

GRUB_ITEMS=(none "None / skip (plain GRUB menu)")
for theme in "${GRUB_THEMES[@]}"; do
    GRUB_ITEMS+=("$theme" "$theme")
done

GRUB_THEME_NAME="$(dlg_capture --title "GRUB theme" --default-item none \
    --menu "Choose a theme for the GRUB boot menu." 0 "$BOX_W" 0 \
    "${GRUB_ITEMS[@]}")" || abort
[[ "$GRUB_THEME_NAME" != "none" ]] || GRUB_THEME_NAME=""

# ---------------- PLYMOUTH THEME ----------------

mapfile -t _remote_themes < <(repo_list_archives plymouth-themes || true)
if [[ "${#_remote_themes[@]}" -gt 0 ]]; then
    PLYMOUTH_THEMES=("${_remote_themes[@]}")
else
    info "Could not list plymouth-themes/ in the repo -- using the built-in theme list."
fi

PLY_ITEMS=(none "None / skip (no boot splash)")
for theme in "${PLYMOUTH_THEMES[@]}"; do
    PLY_ITEMS+=("$theme" "")
done

PLYMOUTH_SELECTED="$(dlg_capture --title "Plymouth boot splash" --default-item none \
    --menu "Choose a Plymouth boot splash theme." 0 "$BOX_W" 0 \
    "${PLY_ITEMS[@]}")" || abort
[[ "$PLYMOUTH_SELECTED" != "none" ]] || PLYMOUTH_SELECTED=""

# ---------------- OTHER OPERATING SYSTEMS (os-prober) ----------------

OS_PROBER_MODE="internal"
if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    OS_PROBER_MODE="$(dlg_capture --title "Other operating systems" --default-item internal \
        --menu "How should GRUB look for other operating systems (e.g. Windows or another Linux)?" \
        0 "$BOX_W" 0 \
        internal "Windows/Linux on INTERNAL disks only (recommended)" \
        all      "Everything os-prober finds (USB sticks, external disks, ...)" \
        off      "Don't add other operating systems to the menu")" || abort
    [[ "$OS_PROBER_MODE" != "off" ]] || ENABLE_OS_PROBER="no"
else
    OS_PROBER_MODE="off"
fi

# ---------------- CONFIRM ----------------

SUMMARY_FILE="$(mktemp)"
{
printf '\n'
printf '%s\n' "============================================================"
printf '%s\n' "Arch Btrfs/Snapper setup"
printf '%s\n' "============================================================"
printf '%s\n' "LUKS device : $LUKS_DEVICE"
printf '%s\n' "LUKS UUID   : $LUKS_UUID"
printf '%s\n' "Btrfs UUID  : $ROOT_BTRFS_UUID"
printf '%s\n' "Mapper name : $CRYPT_NAME"
printf '%s\n' "Root subvol : $ROOT_SUBVOL"
printf '%s\n' "Root        : $ROOT_SOURCE"
printf '%s\n' "Snapshots   : $SNAP_SOURCE"
printf '%s\n' "Boot        : $(findmnt -n -o SOURCE /boot)"
printf '%s\n' "EFI         : $(findmnt -n -o SOURCE /efi)"
printf '%s\n' "Microcode   : ${UCODE_PKG:-none}"
printf '%s\n' "GRUB Theme  : ${GRUB_THEME_NAME:-none}"
printf '%s\n' "Plymouth    : ${PLYMOUTH_SELECTED:-none}"
printf '%s\n' "UEFI entry  : $GRUB_BOOTLOADER_ID"
printf '%s\n' "OS prober   : $ENABLE_OS_PROBER (mode: $OS_PROBER_MODE)"
printf '%s\n' "============================================================"
printf '\n'
printf '%s\n' "The script will configure:"
printf '%s\n' "  * systemd-based mkinitcpio initramfs"
printf '%s\n' "  * LUKS2 unlock via sd-encrypt"
if [[ -n "$PLYMOUTH_SELECTED" ]]; then
    printf '%s\n' "  * Plymouth theme: $PLYMOUTH_SELECTED (downloaded from GitHub)"
else
    printf '%s\n' "  * Plymouth: skipped (no theme selected)"
fi
printf '%s\n' "  * GRUB + grub-btrfs"
printf '%s\n' "  * GRUB remembers last-booted entry (GRUB_DEFAULT=saved)"
printf '%s\n' "  * Snapper for / only"
printf '%s\n' "  * snap-pac pre/post pacman snapshots"
printf '%s\n' "  * boot + daily snapshots"
printf '%s\n' "  * automatic cleanup"
printf '%s\n' "  * fstrim.timer (periodic TRIM instead of online discard)"
if [[ -n "$GRUB_THEME_NAME" ]]; then
    printf '%s\n' "  * GRUB theme: $GRUB_THEME_NAME (downloaded from GitHub)"
fi
if [[ "$ENABLE_BTRFS_QUOTA" == "yes" ]]; then
    printf '%s\n' "  * Btrfs quota support (qgroups)"
else
    printf '%s\n' "  * Btrfs quota support: SKIPPED (ENABLE_BTRFS_QUOTA=no)"
fi
if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    if [[ "$OS_PROBER_MODE" == "internal" ]]; then
        printf '%s\n' "  * os-prober enabled -- internal disks only (USB/removable skipped)"
    else
        printf '%s\n' "  * os-prober enabled -- scans every disk it can see"
    fi
fi
if [[ "$STRIP_EFI_BOOTNEXT_ENTRIES" == "yes" ]]; then
    printf '%s\n' "  * strip 'EFI BootNext' clutter entries from the GRUB menu"
fi
printf '%s\n' "============================================================"
printf '\n'

if [[ "${#WARN_LIST[@]}" -gt 0 ]]; then
    printf '%s\n' "Warnings from the system checks:"
    for w in "${WARN_LIST[@]}"; do
        printf '%s\n' "  [!] $w"
    done
    printf '\n'
fi
printf '%s\n' "(scroll with the arrow keys / PgUp / PgDn)"
} > "$SUMMARY_FILE"

dlg --title "Summary -- review before anything is changed" \
    --exit-label "Continue" --textbox "$SUMMARY_FILE" "$LOG_H" "$LOG_W"
rm -f "$SUMMARY_FILE"

ask_yes "Confirm" "Apply this configuration now?\n\nBackups of the files that get changed are written to:\n  $BACKUP_DIR" yes || abort

# ============================================================
# SETUP (unattended; live progress in a dialog --gauge)
#
# Everything below runs inside run_setup(). NOTE: the body is
# deliberately not indented -- the heredocs inside must keep their
# terminators in column 0.
#
# run_with_gauge gives the function FD 3 pointing at the gauge; stdout
# is redirected inside run_setup to $LOG_FILE so that every log/info/warn
# line and every command's output are captured cleanly. Only gauge_msg
# writes the percent+message+phase frames to FD 3.
# ============================================================

run_setup() {
exec 3>&1
exec 1>>"$LOG_FILE"

# ---- Phase tree shown inside the gauge prompt ----
local -a PHASES=(
    "Backups created"
    "Packages installed"
    "Themes installed (GRUB / Plymouth)"
    "Snapper configured"
    "Initramfs rebuilt"
    "GRUB installed"
    "GRUB config generated"
    "Snapshots created"
    "Done"
)
local CURRENT_PHASE=0
local -a CUR_ITEMS=()
local CUR_IDX=0
local WIN=5

_phase_prompt() {
    local i j n start end out=""
    for ((i=0; i<${#PHASES[@]}; i++)); do
        # Progress marker line -- see archInstall.sh for the rationale.
        if (( i == CURRENT_PHASE && CURRENT_PHASE > 0 )); then
            out+="$(printf '%*s' $(( BOX_W - 8 )) '' | tr ' ' '-')"$'\n'
        fi    
        if (( i < CURRENT_PHASE )); then
            out+="  [x] ${PHASES[i]}"$'\n'
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

set_phase() { CURRENT_PHASE="$1"; }
set_items() { CUR_ITEMS=("$@"); CUR_IDX=0; }
advance()   { CUR_IDX=$((CUR_IDX + 1)); }

# ---------------- BACKUPS ----------------

set_phase 0
set_items "/etc/fstab" "/etc/mkinitcpio.conf" "/etc/default/grub" "Snapper config"

gauge_msg 2 "Backing up configuration files..."
log "Backing up configuration files..."

mkdir -p "$BACKUP_DIR"
for f in \
    /etc/fstab \
    /etc/mkinitcpio.conf \
    /etc/default/grub \
    /etc/snapper/configs/root
do
    if [[ -f "$f" ]]; then
        cp -a "$f" "$BACKUP_DIR/"
    fi
    advance
done
info "Backups: $BACKUP_DIR"

# ---------------- PACKAGES ----------------

set_phase 1
local -a _pkg_items=(
    "Core: btrfs-progs, cryptsetup"
    "Snapshots: snapper, snap-pac"
    "Boot: grub, grub-btrfs, efibootmgr"
    "Tools: git, curl, inotify-tools, btrfs-assistant"
)
[[ -z "$PLYMOUTH_SELECTED" ]] || _pkg_items+=("Plymouth")
[[ -n "$UCODE_PKG" ]] && _pkg_items+=("Microcode: $UCODE_PKG")
[[ "$ENABLE_OS_PROBER" == "yes" ]] && _pkg_items+=("Other OS: os-prober, ntfs-3g, fuse3")
set_items "${_pkg_items[@]}"

gauge_msg 5 "Installing required packages..."
log "Installing required packages..."

PACKAGES=(
    btrfs-progs
    cryptsetup
    snapper
    snap-pac
    grub
    grub-btrfs
    inotify-tools
    btrfs-assistant
    git
    curl
    efibootmgr
)
[[ -n "$UCODE_PKG" ]] && PACKAGES+=("$UCODE_PKG")
[[ -z "$PLYMOUTH_SELECTED" ]] || PACKAGES+=(plymouth)
if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    PACKAGES+=(os-prober ntfs-3g fuse3)
fi

pacman -S --needed --noconfirm --noprogressbar "${PACKAGES[@]}"

# Mark every sub-item as done (single pacman transaction).
CUR_IDX=${#CUR_ITEMS[@]}

# ---------------- GRUB THEME INSTALL ----------------
#
# Archives are extracted into a scratch directory first and the theme is
# located INSIDE it (theme.txt / *.plymouth), so it doesn't matter what the
# archive's own top-level folder is called -- the theme is installed under
# the name it was selected by.

set_phase 2
set_items \
    "GRUB theme: ${GRUB_THEME_NAME:-none}" \
    "Plymouth theme: ${PLYMOUTH_SELECTED:-none}"

if [[ -n "$GRUB_THEME_NAME" ]]; then
    gauge_msg 10 "Installing GRUB theme: $GRUB_THEME_NAME..."
    log "Installing GRUB theme: $GRUB_THEME_NAME..."

    GRUB_THEME_URL="${GRUB_THEMES_BASE_URL}/${GRUB_THEME_NAME}.tar.xz"
    GRUB_WORK="$(mktemp -d)"

    if curl -fsSL -o "$GRUB_WORK/theme.tar.xz" "$GRUB_THEME_URL" \
        && mkdir "$GRUB_WORK/x" \
        && tar -xf "$GRUB_WORK/theme.tar.xz" -C "$GRUB_WORK/x"; then
        GRUB_THEME_TXT="$(find "$GRUB_WORK/x" -name theme.txt -type f -print -quit)"
        if [[ -n "$GRUB_THEME_TXT" ]]; then
            mkdir -p /boot/grub/themes
            rm -rf "/boot/grub/themes/${GRUB_THEME_NAME}"
            cp -a "$(dirname "$GRUB_THEME_TXT")" "/boot/grub/themes/${GRUB_THEME_NAME}"
            chmod -R u=rwX,go=rX "/boot/grub/themes/${GRUB_THEME_NAME}"
            info "Theme files installed: /boot/grub/themes/${GRUB_THEME_NAME}/theme.txt"

            sed -i -E '/^[[:space:]]*GRUB_BACKGROUND=/d' "$GRUB_DEFAULT_FILE"
            set_grub_option "GRUB_THEME" "\"/boot/grub/themes/${GRUB_THEME_NAME}/theme.txt\"" "$GRUB_DEFAULT_FILE"
            log "GRUB theme installed and set: $GRUB_THEME_NAME"
        else
            warn "No theme.txt found inside the $GRUB_THEME_NAME archive -- skipping GRUB_THEME."
        fi
    else
        warn "Could not download/extract $GRUB_THEME_URL"
        warn "Check that the archive exists at that path in the repo. Skipping GRUB theme installation."
    fi
    rm -rf "$GRUB_WORK"
else
    info "No GRUB theme selected -- skipping."
fi
advance

# ---------------- PLYMOUTH THEME INSTALL ----------------

if [[ -n "$PLYMOUTH_SELECTED" ]]; then
    gauge_msg 15 "Installing Plymouth theme: $PLYMOUTH_SELECTED..."
    log "Installing Plymouth theme: $PLYMOUTH_SELECTED..."

    THEME_URL="${PLYMOUTH_THEMES_BASE_URL}/${PLYMOUTH_SELECTED}.tar.xz"
    mkdir -p "$PLYMOUTH_TMP/x"

    if curl -fsSL -o "$PLYMOUTH_TMP/theme.tar.xz" "$THEME_URL" \
        && tar -xf "$PLYMOUTH_TMP/theme.tar.xz" -C "$PLYMOUTH_TMP/x"; then
        PLYMOUTH_FILE="$(find "$PLYMOUTH_TMP/x" -name '*.plymouth' -type f -print -quit)"
        if [[ -n "$PLYMOUTH_FILE" ]]; then
            # plymouth-set-default-theme needs themes/<name>/<name>.plymouth,
            # so the install name comes from the .plymouth file itself.
            PLYMOUTH_THEME_ID="$(basename "$PLYMOUTH_FILE" .plymouth)"
            if [[ -z "$PLYMOUTH_THEME_ID" || "$PLYMOUTH_THEME_ID" == *..* ]]; then
                warn "Unusable .plymouth file name '$PLYMOUTH_FILE' -- skipping the theme."
            else
                PLYMOUTH_DEST="/usr/share/plymouth/themes/${PLYMOUTH_THEME_ID}"
                mkdir -p /usr/share/plymouth/themes
                rm -rf "$PLYMOUTH_DEST"
                cp -a "$(dirname "$PLYMOUTH_FILE")" "$PLYMOUTH_DEST"
                info "Theme files installed: $PLYMOUTH_DEST"
                if [[ "$PLYMOUTH_THEME_ID" != "$PLYMOUTH_SELECTED" ]]; then
                    info "(installed as '$PLYMOUTH_THEME_ID' -- the name inside the archive)"
                fi

                if command -v plymouth-set-default-theme >/dev/null 2>&1; then
                    if plymouth-set-default-theme "$PLYMOUTH_THEME_ID"; then
                        PLYMOUTH_OK=1
                        log "Plymouth theme set successfully."
                    else
                        warn "plymouth-set-default-theme failed for '$PLYMOUTH_THEME_ID'."
                    fi
                else
                    warn "plymouth-set-default-theme not found; keeping default theme."
                fi
            fi
        else
            warn "No .plymouth file found inside the $PLYMOUTH_SELECTED archive -- theme not installed."
        fi
    else
        warn "Could not download/extract $THEME_URL"
        warn "Check that the archive exists at that path in the repo. Skipping Plymouth theme installation."
    fi
else
    info "No Plymouth theme selected -- skipping."
fi
advance

# ---------------- SNAPPER ----------------

set_phase 3
set_items \
    "Check /.snapshots mount" \
    "Create Snapper config" \
    "Retention policy" \
    "Btrfs quota" \
    "Snapper timers" \
    "fstrim.timer"

gauge_msg 20 "Checking /.snapshots..."
log "Checking /.snapshots..."

SNAPSHOT_SOURCE="$(findmnt -n -o SOURCE /.snapshots)"
[[ "$SNAPSHOT_SOURCE" == *"@snapshots"* ]] || \
    warn "/.snapshots is mounted, but its source does not look like @snapshots."

chmod 750 /.snapshots || true
advance

gauge_msg 25 "Configuring Snapper for / ..."
log "Configuring Snapper for / ..."

if [[ ! -f "/etc/snapper/configs/$SNAPPER_CONFIG" ]]; then
    log "Creating Snapper root configuration..."
    umount /.snapshots
    rmdir /.snapshots 2>/dev/null || true
    snapper --no-dbus -c "$SNAPPER_CONFIG" create-config /

    if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
        btrfs subvolume delete /.snapshots
    fi

    mkdir -p /.snapshots
    chmod 750 /.snapshots
    mount /.snapshots

    findmnt -n /.snapshots >/dev/null || \
        die "Could not mount the existing @snapshots subvolume."
else
    info "Snapper config already exists; keeping it."
fi

snapper -c "$SNAPPER_CONFIG" get-config >/dev/null
advance

gauge_msg 30 "Configuring snapshot retention..."
log "Configuring snapshot retention..."

snapper -c "$SNAPPER_CONFIG" set-config \
    "NUMBER_CLEANUP=yes" \
    "NUMBER_MIN_AGE=$MIN_AGE" \
    "NUMBER_LIMIT=$NUMBER_LIMIT" \
    "NUMBER_LIMIT_IMPORTANT=$NUMBER_LIMIT_IMPORTANT" \
    "TIMELINE_CREATE=yes" \
    "TIMELINE_CLEANUP=yes" \
    "TIMELINE_MIN_AGE=$MIN_AGE" \
    "TIMELINE_LIMIT_HOURLY=$TIMELINE_LIMIT_HOURLY" \
    "TIMELINE_LIMIT_DAILY=$TIMELINE_LIMIT_DAILY" \
    "TIMELINE_LIMIT_WEEKLY=$TIMELINE_LIMIT_WEEKLY" \
    "TIMELINE_LIMIT_MONTHLY=$TIMELINE_LIMIT_MONTHLY" \
    "TIMELINE_LIMIT_YEARLY=$TIMELINE_LIMIT_YEARLY" \
    "EMPTY_PRE_POST_CLEANUP=yes" \
    "SPACE_LIMIT=$SPACE_LIMIT" \
    "FREE_LIMIT=$FREE_LIMIT"
advance

if [[ "$ENABLE_BTRFS_QUOTA" == "yes" ]]; then
    gauge_msg 35 "Enabling Btrfs quotas for Snapper..."
    log "Enabling Btrfs quotas for Snapper..."
    snapper -c "$SNAPPER_CONFIG" setup-quota || \
        warn "Snapper quota setup returned non-zero. Check: btrfs qgroup show /"
else
    log "Skipping Btrfs quota setup (ENABLE_BTRFS_QUOTA=no)."
    info "SPACE_LIMIT/FREE_LIMIT-based cleanup will be inactive; NUMBER_LIMIT and TIMELINE_LIMIT_* still apply."
fi
advance

gauge_msg 40 "Enabling Snapper timers..."
log "Enabling Snapper timers..."

systemctl enable --now snapper-cleanup.timer
systemctl enable --now snapper-timeline.timer

if systemctl list-unit-files snapper-boot.timer >/dev/null 2>&1; then
    systemctl enable --now snapper-boot.timer
else
    warn "snapper-boot.timer is not available in this Snapper version."
fi
advance

gauge_msg 45 "Enabling fstrim.timer (periodic TRIM)..."
log "Enabling fstrim.timer (periodic TRIM)..."
systemctl enable --now fstrim.timer
advance

# ---------------- INITRAMFS ----------------

set_phase 4
set_items \
    "Edit HOOKS in mkinitcpio.conf" \
    "Rebuild initramfs (mkinitcpio -P)"

gauge_msg 50 "Configuring mkinitcpio..."
log "Configuring mkinitcpio..."

MKINITCPIO_CONF="/etc/mkinitcpio.conf"
cp -a "$MKINITCPIO_CONF" "$BACKUP_DIR/mkinitcpio.conf.before"
sed -i -E '/^[[:space:]]*HOOKS=/d' "$MKINITCPIO_CONF"

# Drop the block a previous run of this script added (idempotent re-runs).
sed -i '/^# >>> arch-setup HOOKS/,/^# <<< arch-setup HOOKS/d' "$MKINITCPIO_CONF"

# The plymouth hook is only added when a Plymouth theme was chosen.
HOOKS_LINE="HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block ${PLYMOUTH_SELECTED:+plymouth }sd-encrypt filesystems fsck)"
{
    printf '\n# >>> arch-setup HOOKS (systemd initramfs + LUKS2%s)\n' "${PLYMOUTH_SELECTED:+ + Plymouth}"
    printf '%s\n' "$HOOKS_LINE"
    printf '# <<< arch-setup HOOKS\n'
} >> "$MKINITCPIO_CONF"
advance

gauge_msg 54 "Rebuilding initramfs..."
log "Rebuilding initramfs..."
mkinitcpio -P
advance

# ---------------- GRUB INSTALL ----------------

set_phase 5
set_items \
    "Kernel command line" \
    "grub-install" \
    "Stale UEFI cleanup" \
    "grub-btrfs daemon" \
    "Windows ESP search"

gauge_msg 58 "Configuring GRUB kernel parameters..."
log "Configuring GRUB kernel parameters..."

cp -a "$GRUB_DEFAULT_FILE" "$BACKUP_DIR/grub.before"

set_grub_option "GRUB_TIMEOUT"       "5"    "$GRUB_DEFAULT_FILE"
set_grub_option "GRUB_TIMEOUT_STYLE" "menu" "$GRUB_DEFAULT_FILE"

log "Enabling GRUB saved-entry default (boot last used OS automatically)..."
set_grub_option "GRUB_DEFAULT"     "saved" "$GRUB_DEFAULT_FILE"
set_grub_option "GRUB_SAVEDEFAULT" "true"  "$GRUB_DEFAULT_FILE"

if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    log "Enabling os-prober so GRUB detects other operating systems..."
    set_grub_option "GRUB_DISABLE_OS_PROBER" "false" "$GRUB_DEFAULT_FILE"

    if [[ "$OS_PROBER_MODE" == "internal" ]]; then
        OS_SKIP_LIST="$(external_skip_list)"
        set_grub_option "GRUB_OS_PROBER_SKIP_LIST" "\"${OS_SKIP_LIST}\"" "$GRUB_DEFAULT_FILE"
        if [[ -n "$OS_SKIP_LIST" ]]; then
            info "os-prober will skip these USB/removable filesystems:"
            for entry in $OS_SKIP_LIST; do info "  $entry"; done
        else
            info "No USB/removable disks with filesystems are connected right now."
        fi
        info "(Only devices connected NOW are listed. A USB stick with a different"
        info " UUID plugged in later can still be detected -- re-run this step or add"
        info " its UUID@device to GRUB_OS_PROBER_SKIP_LIST in /etc/default/grub.)"
    elif grep -qE '^#?[[:space:]]*GRUB_OS_PROBER_SKIP_LIST=' "$GRUB_DEFAULT_FILE"; then
        set_grub_option "GRUB_OS_PROBER_SKIP_LIST" '""' "$GRUB_DEFAULT_FILE"
    fi
elif [[ "$OS_PROBER_MODE" == "off" ]]; then
    set_grub_option "GRUB_DISABLE_OS_PROBER" "true" "$GRUB_DEFAULT_FILE"
fi

CURRENT_CMDLINE="$(
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE" |
        head -n1 |
        cut -d= -f2- |
        sed 's/^"//;s/"$//' || true
)"

CURRENT_CMDLINE="$(
    printf '%s' "$CURRENT_CMDLINE" |
        sed -E \
            's/(^| )cryptdevice=[^ ]+//g;
             s/(^| )rd\.luks\.name=[^ ]+//g;
             s/(^| )root=UUID=[^ ]+//g;
             s/(^| )root=\/dev\/mapper\/[^ ]+//g;
             s/(^| )rootflags=[^ ]+//g;
             s/[[:space:]]+/ /g;
             s/^ //;
             s/ $//'
)"

NEW_CMDLINE="$CURRENT_CMDLINE rd.luks.name=${LUKS_UUID}=${CRYPT_NAME} root=/dev/mapper/${CRYPT_NAME} rootflags=subvol=${ROOT_SUBVOL} quiet loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"
[[ -z "$PLYMOUTH_SELECTED" ]] || NEW_CMDLINE+=" splash"

# De-duplicate (e.g. 'quiet' already set by archInstall.sh must not appear
# twice) and drop a stale 'splash' when no Plymouth theme was chosen.
NEW_CMDLINE="$(tr -s ' ' '\n' <<< "$NEW_CMDLINE" \
    | awk -v keep_splash="${PLYMOUTH_SELECTED:+1}" 'NF && !seen[$0]++ && ($0 != "splash" || keep_splash)' \
    | paste -sd' ' -)"

set_grub_option "GRUB_CMDLINE_LINUX_DEFAULT" "\"$NEW_CMDLINE\"" "$GRUB_DEFAULT_FILE"

if grep -qE '^[[:space:]]*GRUB_THEME=' /etc/default/grub; then
    THEME_PATH=$(grep -E '^[[:space:]]*GRUB_THEME=' /etc/default/grub | cut -d= -f2 | tr -d '"')
    if [[ -f "$THEME_PATH" ]]; then
        log "GRUB theme configured: $THEME_PATH"
    else
        warn "GRUB theme file not found: $THEME_PATH"
    fi
fi
advance

gauge_msg 66 "Installing GRUB for UEFI (boot entry '$GRUB_BOOTLOADER_ID')..."
log "Installing/reinstalling GRUB for UEFI with boot entry '$GRUB_BOOTLOADER_ID'..."

grub-install \
    --target="$(efi_grub_target)" \
    --efi-directory=/efi \
    --bootloader-id="$GRUB_BOOTLOADER_ID" \
    --recheck
advance

gauge_msg 70 "Cleaning up stale UEFI entries..."

if command -v efibootmgr >/dev/null 2>&1; then
    log "Scanning for stale UEFI boot entries on this ESP (GRUB / UEFI OS)..."

    ESP_PARTUUID="$(findmnt -n -o PARTUUID /efi 2>/dev/null || true)"
    if [[ -z "$ESP_PARTUUID" ]]; then
        warn "Could not determine PARTUUID of /efi -- skipping stale entry cleanup."
    else
        info "Our ESP PARTUUID: $ESP_PARTUUID"

        while IFS= read -r line; do
            entry_num="$(printf '%s' "$line" | awk '{print $1}' | sed -E 's/^Boot//; s/\*$//')"
            entry_name="$(printf '%s' "$line" | sed -E 's/^Boot[0-9A-Fa-f]+\*?[[:space:]]+//; s/[[:space:]]+HD\(.*$//')"

            [[ "$entry_name" == "GRUB" || "$entry_name" == "UEFI OS" ]] || continue
            printf '%s' "$line" | grep -q "$ESP_PARTUUID" || continue

            if efibootmgr -b "$entry_num" -B >/dev/null 2>&1; then
                info "Removed stale UEFI entry Boot$entry_num ($entry_name) on this ESP"
            else
                warn "Failed to remove UEFI entry Boot$entry_num ($entry_name)"
            fi
        done < <(efibootmgr -v | grep -E '^Boot[0-9A-Fa-f]{4}')
    fi
else
    warn "efibootmgr not found -- stale UEFI entries (if any) were not removed."
fi
advance

gauge_msg 74 "Enabling grub-btrfs daemon..."
log "Enabling grub-btrfs daemon..."

if systemctl list-unit-files grub-btrfsd.service >/dev/null 2>&1; then
    systemctl enable --now grub-btrfsd.service
else
    warn "grub-btrfsd.service not found."
fi
advance

# ---------------- WINDOWS ESP AUTO-MOUNT ----------------

WIN_ESP=""
WIN_ESP_MOUNT="/mnt/win-esp"

if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    gauge_msg 82 "Searching for a Windows ESP (for os-prober detection)..."
    log "Searching for a Windows ESP (for os-prober detection)..."
    mkdir -p "$WIN_ESP_MOUNT"

    while read -r dev; do
        [[ -b "$dev" ]] || continue
        if findmnt -n -o SOURCE /efi 2>/dev/null | grep -q "/$(basename "$dev")\$"; then
            continue
        fi
        if [[ "$OS_PROBER_MODE" == "internal" ]] && is_external_disk_part "$dev"; then
            continue
        fi
        if mount -o ro "$dev" "$WIN_ESP_MOUNT" 2>/dev/null; then
            if [[ -f "$WIN_ESP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
                WIN_ESP="$dev"
                info "Found Windows ESP: $dev (temporarily mounted at $WIN_ESP_MOUNT)"
                break
            fi
            umount "$WIN_ESP_MOUNT" 2>/dev/null || true
        fi
    done < <(lsblk -rno NAME,FSTYPE | awk '$2=="vfat"{print "/dev/"$1}')

    if [[ -z "$WIN_ESP" ]]; then
        info "No Windows ESP found. (Windows may not be installed, or it's already visible to grub-mkconfig.)"
    fi
fi
advance

# ---------------- GRUB CONFIG ----------------

set_phase 6
set_items "Generate grub.cfg" "Strip EFI BootNext entries"

gauge_msg 88 "Generating GRUB configuration..."
log "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg
advance

if [[ "$STRIP_EFI_BOOTNEXT_ENTRIES" == "yes" ]]; then
    gauge_msg 92 "Removing 'EFI BootNext' entries from the GRUB menu..."
    log "Removing 'EFI BootNext' entries from the GRUB menu..."
    strip_efi_bootnext_entries
    info "EFI BootNext entries stripped from /boot/grub/grub.cfg."
fi
advance

if [[ -n "$WIN_ESP" ]]; then
    log "Unmounting temporary Windows ESP mount ($WIN_ESP_MOUNT)..."
    umount "$WIN_ESP_MOUNT" 2>/dev/null || true
    rmdir "$WIN_ESP_MOUNT" 2>/dev/null || true
fi

# ---------------- INITIAL SNAPSHOT ----------------

set_phase 7
set_items "Create initial snapshot" "Snapper cleanup"

gauge_msg 95 "Creating initial protected system snapshot..."
log "Creating initial protected system snapshot..."

INITIAL_SNAPSHOT_ID="$(
    snapper -c "$SNAPPER_CONFIG" create \
        --cleanup-algorithm number \
        --description "Initial Arch system after Btrfs/Snapper setup" \
        --print-number
)"
advance

gauge_msg 98 "Running initial Snapper cleanup..."
log "Running initial Snapper cleanup..."

snapper -c "$SNAPPER_CONFIG" cleanup number || true
snapper -c "$SNAPPER_CONFIG" cleanup timeline || true
advance

# ---------------- FINAL REPORT ----------------

set_phase 8
gauge_msg 99 "Writing final status report..."
log "Setup complete."

printf '\n'
echo "============================================================"
echo " FINAL STATUS"
echo "============================================================"

echo
echo "--- Filesystems ---"
findmnt / /home /.snapshots /boot /efi || true

echo
echo "--- Btrfs subvolumes ---"
btrfs subvolume list / || true

echo
echo "--- LUKS ---"
cryptsetup status "$CRYPT_NAME" 2>/dev/null || true

echo
echo "--- Snapper config ---"
snapper -c "$SNAPPER_CONFIG" get-config

echo
echo "--- Snapshots ---"
snapper -c "$SNAPPER_CONFIG" list

echo
echo "--- Timers ---"
systemctl list-timers --all | grep -E 'snapper|grub-btrfs|fstrim' || true

echo
echo "--- Plymouth theme ---"
if [[ "$PLYMOUTH_OK" -eq 1 ]]; then
    plymouth-set-default-theme || true
else
    echo "Custom theme was NOT applied (see warnings above). Default theme is active."
fi

echo
echo "--- GRUB command line ---"
grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || true

echo
echo "--- Other operating systems in the GRUB menu ---"
OS_ENTRIES="$(grep -E "^menuentry '.*osprober" /boot/grub/grub.cfg 2>/dev/null | sed -E "s/^menuentry '([^']*)'.*/  \1/" || true)"
echo "${OS_ENTRIES:-  (none found)}"

echo
echo "--- EFI BootNext entries left in the GRUB menu ---"
BOOTNEXT_LEFT="$(grep -c '(EFI BootNext)' /boot/grub/grub.cfg 2>/dev/null || true)"
echo "  ${BOOTNEXT_LEFT:-0} (should be 0)"

echo
echo "--- GRUB saved default ---"
grep -E '^[[:space:]]*(GRUB_DEFAULT|GRUB_SAVEDEFAULT|GRUB_DISABLE_OS_PROBER)=' /etc/default/grub || true

echo
echo "--- GRUB theme ---"
grep -E '^[[:space:]]*GRUB_THEME=' /etc/default/grub || true
if [[ -n "$GRUB_THEME_NAME" && -f "/boot/grub/themes/${GRUB_THEME_NAME}/theme.txt" ]]; then
    echo "GRUB theme installed at: /boot/grub/themes/${GRUB_THEME_NAME}"
else
    echo "GRUB theme not installed."
fi

echo
echo "--- UEFI boot entries ---"
if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr | grep -E '^Boot[0-9A-Fa-f]{4}' || true
fi

echo
echo "--- Initial snapshot ---"
echo "#$INITIAL_SNAPSHOT_ID"

echo
echo "============================================================"
echo " IMPORTANT"
echo "============================================================"
echo
echo "1. /home is intentionally NOT included in Snapper snapshots."
echo
echo "2. /boot and /efi are unencrypted by design."
echo
echo "3. Root + home + snapshots are protected by the LUKS2 container."
echo
echo "4. Snapper keeps approximately:"
echo "     - $NUMBER_LIMIT number snapshots"
echo "     - $NUMBER_LIMIT_IMPORTANT important number snapshots"
echo "     - $TIMELINE_LIMIT_DAILY daily snapshots"
echo "     - $TIMELINE_LIMIT_WEEKLY weekly snapshots"
echo "     - $TIMELINE_LIMIT_MONTHLY monthly snapshots"
echo
echo "5. Pacman transactions are handled by snap-pac."
echo
echo "6. GRUB will contain grub-btrfs snapshot entries when snapshots"
echo "   are detected."
echo
echo "7. If something breaks, DO NOT immediately delete the snapshot."
echo "   First boot a known-good snapshot from GRUB, verify the system,"
echo "   then perform a Snapper rollback if needed."
echo
echo "8. Before reboot, inspect:"
echo "     lsblk -f"
echo "     cat /etc/fstab"
echo "     cat /etc/default/grub"
echo "     cat /etc/mkinitcpio.conf"
echo
echo "Configuration backups:"
echo "  $BACKUP_DIR"
echo
echo "============================================================"

gauge_msg 100 "Setup complete."

exec 1>&3
exec 3>&-
}

# Taller gauge so the phase tree + sub-steps fit comfortably. Capped to
# what the terminal can actually show; ui_init guarantees TERM_LINES >= 20.
GAUGE_HEIGHT=$(( TERM_LINES - 2 ))
(( GAUGE_HEIGHT > 22 )) && GAUGE_HEIGHT=22
(( GAUGE_HEIGHT < 12 )) && GAUGE_HEIGHT=12

run_with_gauge "Btrfs / Snapper / GRUB setup" "$LOG_FILE" run_setup

if [[ "$RUN_GAUGE_RC" -ne 0 ]]; then
    _tail="$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo '(log unavailable)')"
    msg_box "Setup FAILED" "The setup did not finish.\n\nLast lines of the log:\n\n${_tail}\n\nNothing was deleted -- backups of the changed files are in:\n  $BACKUP_DIR\n\nFull log:\n  $LOG_FILE"
    exit 1
fi

msg_box "Setup complete" "Btrfs / Snapper / GRUB setup finished.\n\nBackups of the changed files:\n  $BACKUP_DIR\n\nFull log:\n  $LOG_FILE\n\nBefore rebooting you can inspect: lsblk -f, /etc/fstab, /etc/default/grub, /etc/mkinitcpio.conf"

if ask_yes "Reboot" "Reboot now?" no; then
    clear
    reboot
fi
clear
