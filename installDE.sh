#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: Desktop environment install (Phase 1.5)
#
# Run this on the installed system, as root (or it will re-launch
# itself with sudo). Run it any time after archInstall.sh -- before
# or after setupAfterInstall.sh, doesn't matter which order.
#
# Installs GNOME, KDE Plasma, or XFCE (X11 -- Wayland support on XFCE
# is still experimental/unstable upstream) -- full or minimal package
# set -- and enables the matching display manager/greeter.
#
# This script only installs packages and writes config files. It does
# not touch partitioning, LUKS, Btrfs, Snapper, or GRUB.
# ============================================================

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
        echo "       URL: ${_repo_url}/lib.sh (HTTP ${_code:-000}; 404 = not pushed to the repo, 000 = no network)" >&2
        echo "       Put lib.sh in the same folder as this script and run it again." >&2
        exit 1
    fi
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKTITLE="Arch Linux installer -- desktop environment"
LOG_FILE="/var/log/installDE.log"

trap 'die "Failed at line $LINENO."' ERR

# Non-interactive mode (used by archInstall.sh, which runs this script
# inside the new system's chroot): set ASSUME_YES=1 together with
# DE_CHOICE (1=GNOME 2=KDE 3=XFCE), INSTALL_MODE (full|minimal) and
# TARGET_USER, and no dialog is shown. Without them it asks via dialog.
INTERACTIVE=1
[[ -z "${ASSUME_YES:-}" ]] || INTERACTIVE=0

# Optional, only used when installing GNOME. Empty means "don't touch
# the current Formats setting". Set by archInstall.sh to the LC_TIME etc.
# locale chosen in the "Regional formats" dialog; can also be set by hand
# when running this script standalone:
#   FORMAT_LOCALE=hr_HR.UTF-8 ./installDE.sh
FORMAT_LOCALE="${FORMAT_LOCALE:-}"

# ---------------- BASIC CHECKS ----------------

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "This script needs root, and sudo isn't installed to elevate automatically. Run it with: su -c ./installDE.sh"
    echo "Not running as root -- re-launching with sudo (you may be asked for your password)."
    exec sudo -- "$0" "$@"
fi

command -v pacman >/dev/null || die "pacman not found -- is this an Arch system?"

if (( INTERACTIVE )); then
    ensure_dialog
    ui_init
fi

# ---------------- TARGET USER ----------------
#
# Desktop-specific defaults (GNOME dark theme, etc.) get applied to a
# real user's home, not root's. Default to the first UID >= 1000 human
# account if there is exactly one; otherwise ask.

CANDIDATE_USERS=()
while IFS=: read -r uname _ uid _; do
    [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]] && CANDIDATE_USERS+=("$uname")
done < /etc/passwd

if [[ -n "${TARGET_USER:-}" ]]; then
    id -u "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."
elif [[ "${#CANDIDATE_USERS[@]}" -eq 1 ]]; then
    TARGET_USER="${CANDIDATE_USERS[0]}"
elif [[ "${#CANDIDATE_USERS[@]}" -gt 1 ]]; then
    (( INTERACTIVE )) || die "Several regular users exist -- set TARGET_USER."
    USER_ITEMS=()
    for u in "${CANDIDATE_USERS[@]}"; do USER_ITEMS+=("$u" ""); done
    TARGET_USER="$(dlg_capture --title "Target user" \
        --menu "Configure the desktop environment for which user?" \
        0 "$BOX_W" 0 "${USER_ITEMS[@]}")" || abort
else
    die "No regular (non-system) user found. Create one first, e.g.: useradd -m -G wheel <name>"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Could not determine home directory for $TARGET_USER."
TARGET_GROUP="$(id -gn "$TARGET_USER")"

# UI language of the system (LANG from /etc/locale.conf, written by
# archInstall.sh). Used for KDE's language setting below; this script runs
# as a separate process, so it has to read it from the system itself.
SYSTEM_LANG="$(sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | head -n1 || true)"
SYSTEM_LANG="${SYSTEM_LANG:-${LANG:-en_US.UTF-8}}"

# ---------------- DESKTOP ENVIRONMENT ----------------

if [[ -z "${DE_CHOICE:-}" ]]; then
    (( INTERACTIVE )) || die "DE_CHOICE must be set in non-interactive mode."
    DE_CHOICE="$(dlg_capture --title "Desktop environment" --default-item 1 \
        --menu "Which desktop environment do you want to install?" \
        0 "$BOX_W" 0 \
        1 "GNOME (Wayland)" \
        2 "KDE Plasma (Wayland)" \
        3 "XFCE (X11)" \
        4 "None / cancel")" || abort
fi

[[ "$DE_CHOICE" == "4" ]] && abort "Nothing to do."
[[ "$DE_CHOICE" == "1" || "$DE_CHOICE" == "2" || "$DE_CHOICE" == "3" ]] || die "Invalid DE_CHOICE '$DE_CHOICE' (use 1, 2 or 3)."

if [[ -z "${INSTALL_MODE:-}" ]]; then
    (( INTERACTIVE )) || die "INSTALL_MODE must be set in non-interactive mode."
    INSTALL_MODE="$(dlg_capture --title "Package set" --default-item full \
        --menu "Full or minimal package set?" 0 "$BOX_W" 0 \
        full    "Full -- complete desktop with its usual applications" \
        minimal "Minimal -- just the desktop and the essentials")" || abort
fi
[[ "$INSTALL_MODE" == "minimal" ]] || INSTALL_MODE="full"

DE_PACKAGES=()
DM_SERVICE=""

# Common Wayland packages for the Wayland DEs (portals, qt support, etc.)
WAYLAND_COMMON=(
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    qt5-wayland
    qt6-wayland
    polkit
    polkit-gnome
)

# Common X11 packages for XFCE -- no qt-wayland/portal-wayland bits
# needed since it runs on Xorg, not a Wayland compositor.
X11_COMMON=(
    xorg-server
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    polkit
    polkit-gnome
)

case "$DE_CHOICE" in
    1)
        DE_NAME="GNOME ($INSTALL_MODE) [Wayland]"
        if [[ "$INSTALL_MODE" == "full" ]]; then
            # Full GNOME = the official `gnome` group + the CURRENT contents of
            # the `gnome-extra` group minus the games, read from the package
            # database -- so packages that are added/renamed upstream are picked
            # up automatically instead of going stale in a hardcoded list.
            GNOME_GAMES=(
                aisleriot atomix five-or-more four-in-a-row gnome-2048 gnome-chess
                gnome-klotski gnome-mahjongg gnome-mines gnome-nibbles gnome-robots
                gnome-sudoku gnome-taquin gnome-tetravex hitori iagno lightsoff
                quadrapassel swell-foop tali
            )
            GNOME_EXTRA=()
            mapfile -t GNOME_EXTRA < <(pacman -Sgq gnome-extra 2>/dev/null \
                | grep -vxFf <(printf '%s\n' "${GNOME_GAMES[@]}") || true)
            if [[ "${#GNOME_EXTRA[@]}" -eq 0 ]]; then
                warn "Could not read the gnome-extra group -- using the built-in list."
                GNOME_EXTRA=(
                    chatty d-spy dconf-editor endeavour ghex gnome-boxes gnome-builder
                    gnome-calls gnome-sound-recorder manuals sysprof gnome-browser-connector
                )
            fi
            DE_PACKAGES=(
                gnome                   # official package group -- full core desktop + stock GNOME apps
                "${GNOME_EXTRA[@]}"     # gnome-extra without the games
                power-profiles-daemon   # power profile settings in gnome-settings
                bluez                   # Bluetooth protocol stack
                bluez-utils             # provides bluetoothctl
                gnome-tweaks            # essential for tweaking GNOME
                "${WAYLAND_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                gnome-shell
                gnome-control-center
                nautilus
                gnome-terminal
                gdm
                power-profiles-daemon   # power profile settings in gnome-settings
                bluez                   # Bluetooth protocol stack
                bluez-utils             # provides bluetoothctl
                "${WAYLAND_COMMON[@]}"
            )
        fi
        DM_SERVICE="gdm.service"
        ;;
    2)
        DE_NAME="KDE Plasma ($INSTALL_MODE) [Wayland]"
        # NOTE: the Wayland session ships inside plasma-workspace itself.
        # The old 'plasma-workspace-wayland' / 'plasma-wayland-session'
        # packages no longer exist -- naming them made the whole pacman
        # transaction fail with "target not found".
        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                plasma-desktop
                sddm
                plasma-nm               # Wi-Fi/network applet + settings (not part of plasma-desktop)
                plasma-pa               # audio volume applet
                powerdevil              # power management
                bluedevil               # Bluetooth (needs bluez, below)
                bluez
                bluez-utils
                kscreen                 # display configuration
                kinfocenter
                kdeplasma-addons
                kde-gtk-config          # GTK apps follow the Plasma theme
                breeze-gtk
                xdg-desktop-portal-kde
                dolphin
                konsole
                kate
                ark
                gwenview
                okular
                spectacle
                "${WAYLAND_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                plasma-desktop
                sddm
                plasma-nm               # Wi-Fi/network applet + settings (not part of plasma-desktop)
                dolphin
                konsole
                "${WAYLAND_COMMON[@]}"
            )
        fi
        DM_SERVICE="sddm.service"
        ;;
    3)
        DE_NAME="XFCE ($INSTALL_MODE) [X11]"

        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                xfce4                   # official group -- panel, session, settings, thunar, terminal, etc.
                xfce4-goodies           # official group -- extra plugins/apps
                lightdm
                lightdm-gtk-greeter
                network-manager-applet  # nm-applet tray icon (XFCE has no built-in network UI)
                "${X11_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                xfce4
                lightdm
                lightdm-gtk-greeter
                network-manager-applet  # nm-applet tray icon (XFCE has no built-in network UI)
                "${X11_COMMON[@]}"
            )
        fi

        DM_SERVICE="lightdm.service"
        ;;
esac
info "Desktop environment: $DE_NAME"

# ---------------- GPU DRIVERS (detected, not assumed) ----------------
#
# Userspace graphics stack for the GPU(s) actually present. The kernel
# drivers (amdgpu / i915 / xe) are part of the kernel already; what is
# missing on a fresh install is Vulkan (games, Proton) and video decode.
# NVIDIA is deliberately not automated (open vs proprietary module,
# kernel/DKMS choice) -- a warning is shown instead.

GPU_VENDORS="$(detect_gpu_vendors)"
GPU_PACKAGES=(mesa)
for _v in $GPU_VENDORS; do
    case "$_v" in
        amd)    GPU_PACKAGES+=(vulkan-radeon) ;;
        intel)  GPU_PACKAGES+=(vulkan-intel intel-media-driver) ;;
        nvidia) warn "NVIDIA GPU detected -- install the driver yourself (nvidia-open + nvidia-utils); not automated." ;;
    esac
done
DE_PACKAGES+=("${GPU_PACKAGES[@]}")
info "GPU vendor(s): ${GPU_VENDORS:-none detected}  ->  ${GPU_PACKAGES[*]}"

# A single renamed/removed package would make `pacman -S` abort the whole
# transaction ("target not found"). Drop what the repositories don't have
# (with a warning) and install the rest.
_selected_pkgs=("${DE_PACKAGES[@]}")
mapfile -t DE_PACKAGES < <(existing_repo_packages "${_selected_pkgs[@]}" 2>/dev/null)
DE_SKIPPED=()
for _p in "${_selected_pkgs[@]}"; do
    in_array "$_p" "${DE_PACKAGES[@]}" || DE_SKIPPED+=("$_p")
done
for _p in "${DE_SKIPPED[@]}"; do
    warn "Package '$_p' is not in the repositories -- skipped."
done
[[ "${#DE_PACKAGES[@]}" -gt 0 ]] || die "None of the selected packages exist in the repositories -- is the pacman database synced? (run: pacman -Syu)"

# ---------------- CONFIRM ----------------

if (( INTERACTIVE )); then
    _skip_note=""
    if [[ "${#DE_SKIPPED[@]}" -gt 0 ]]; then
        _skip_note="\n\nNot in the repositories (skipped):\n  ${DE_SKIPPED[*]}"
    fi
    ask_yes "Confirm" "Target user:  $TARGET_USER ($TARGET_HOME)\nDesktop:      $DE_NAME\nGPU:          ${GPU_VENDORS:-none detected}\n\nPackages:\n  ${DE_PACKAGES[*]}${_skip_note}\n\nContinue with the installation?" yes || abort
fi

# ---------------- INSTALL ----------------
#
# Everything from here on runs inside run_de_install(): in interactive mode
# with live output in a dialog box (with phase checklist), in
# non-interactive mode (called from archInstall.sh's chroot) output just
# goes to stdout so the caller can parse its "(N/M) installing" lines and
# drive its own gauge. The body is deliberately not indented.

run_de_install() {

# ---- Phase checklist (interactive only) ----
local -a PHASES=(
    "Packages installed"
    "Icon & cursor themes"
    "Display manager enabled"
    "Desktop theme configured"
    "Finalizing"
)
local CURRENT_PHASE=0

_phase_prompt() {
    local i out=""
    for ((i=0; i<${#PHASES[@]}; i++)); do
        # Progress marker line -- see archInstall.sh for the rationale.
        if (( i == CURRENT_PHASE && CURRENT_PHASE > 0 )); then
            out+="$(printf '%*s' $(( BOX_W - 8 )) '' | tr ' ' '-')"$'\n'
        fi

        if (( i < CURRENT_PHASE )); then
            out+="  [x] ${PHASES[i]}"$'\n'
        elif (( i == CURRENT_PHASE )); then
            out+="  [>] ${PHASES[i]}"$'\n'
        else
            out+="  [ ] ${PHASES[i]}"$'\n'
        fi
    done
    printf '%s' "$out"
}

if (( INTERACTIVE )); then
    # Interactive: run our own gauge. FD 3 -> gauge pipe; stdout -> log.
    exec 3>&1
    exec 1>>"$LOG_FILE"
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
else
    # Non-interactive (chroot from archInstall.sh): everything goes to
    # stdout so the caller's while-read loop can parse "(N/M) installing"
    # lines and update ITS gauge. Our own gauge_msg is a no-op.
    gauge_msg() { :; }
    set_phase() { :; }
fi

set_phase 0
gauge_msg 5 "Installing ${DE_NAME} packages -- downloading..."

log "Installing $DE_NAME packages..."

# Stream pacman output. In interactive mode stdout goes to the log and
# only the gauge gets the (phase + percent) frames; in non-interactive
# mode every line (including the "(N/M) installing" markers) is printed
# to stdout so the parent can consume it.
stdbuf -oL pacman -S --needed --noconfirm --noprogressbar "${DE_PACKAGES[@]}" 2>&1 | \
    while IFS= read -r line; do
        printf '%s\n' "$line"
        if [[ "$line" =~ ^\(([0-9]+)/([0-9]+)\)[[:space:]]+installing ]]; then
            _cur="${BASH_REMATCH[1]}"
            _tot="${BASH_REMATCH[2]}"
            gauge_msg "$(( 5 + 45 * _cur / _tot ))" "Installing ${DE_NAME} (${_cur}/${_tot})..."
        fi
    done
[[ "${PIPESTATUS[0]}" -eq 0 ]] || die "pacman failed installing ${DE_NAME}."

# ---------------- ICONS & CURSORS (from GitHub) ----------------
#
# The Reversal icon theme and Deepin cursor theme are downloaded and
# installed system-wide, but they are only *applied* via gsettings,
# which is a GNOME-only mechanism. For KDE and XFCE this step would
# just waste bandwidth, time and disk space on themes that never get
# activated -- so it only runs for GNOME.

set_phase 1
if [[ "$DE_CHOICE" == "1" ]]; then
    gauge_msg 55 "Downloading icon and cursor themes..."
    log "Downloading icon and cursor themes..."

    ICONS_BASE_URL="$REPO_RAW_URL"

    # Download and install the Reversal icon theme.
    #
    # The upstream Reversal repo does not ship pre-built icons -- it ships
    # an install.sh script that generates/installs the icon set for a given
    # color variant. So we download the source archive to a temp directory,
    # extract it, and run its install.sh for each color variant we want to
    # have available (yellow, orange, black, grey).
    log "Downloading Reversal icon theme..."
    ICONS_TMP="$(mktemp -d)"
    ICON_ARCHIVE="$ICONS_TMP/Reversal-icon-theme-master.tar.xz"

    if curl -fsSL -o "$ICON_ARCHIVE" "${ICONS_BASE_URL}/icons/Reversal-icon-theme-master.tar.xz"; then
        log "Extracting Reversal icon theme to $ICONS_TMP..."
        tar -xf "$ICON_ARCHIVE" -C "$ICONS_TMP/"
        rm -f "$ICON_ARCHIVE"

        # The archive extracts to a directory named Reversal-icon-theme-master
        # (or similar). Locate the directory that contains install.sh so we
        # can run it from there, regardless of the exact folder name.
        REVERSAL_INSTALL="$(find "$ICONS_TMP" -maxdepth 2 -name 'install.sh' -type f | head -n1)"

        if [[ -n "$REVERSAL_INSTALL" ]]; then
            REVERSAL_DIR="$(dirname "$REVERSAL_INSTALL")"
            chmod +x "$REVERSAL_INSTALL"

            log "Installing Reversal icon theme color variants..."

            # Yellow is the default variant upstream -- its install.sh takes
            # no color flag (running "./install.sh" alone installs yellow).
            info "==> Reversal: yellow"
            (cd "$REVERSAL_DIR" && ./install.sh) \
                || warn "Reversal install.sh failed for color: yellow"

            # The other three variants need the -t <color> flag.
            for color in orange black grey; do
                info "==> Reversal: $color"
                (cd "$REVERSAL_DIR" && ./install.sh -t "$color") \
                    || warn "Reversal install.sh failed for color: $color"
            done

            info "Reversal icon theme installed (yellow, orange, black, grey)."
        else
            warn "install.sh not found in Reversal archive -- skipping icon theme installation."
        fi

        rm -rf "$ICONS_TMP"
    else
        warn "Could not download Reversal icon theme from ${ICONS_BASE_URL}/icons/"
        rm -rf "$ICONS_TMP"
    fi

    # Download and install cursor theme (Deepin dark).
    # Note: unlike the Reversal icons, the cursor theme is a ready-to-use
    # directory of cursor files, so we just extract it straight into
    # /usr/share/icons/ -- no install.sh needed.
    log "Downloading Deepin dark cursor theme..."
    CURSOR_ARCHIVE="$(mktemp --suffix=.tar.xz)"
    if curl -fsSL -o "$CURSOR_ARCHIVE" "${ICONS_BASE_URL}/cursor/DeppinDark-cursors.tar.xz"; then
        log "Extracting Deepin dark cursor theme to /usr/share/icons/..."
        tar -xf "$CURSOR_ARCHIVE" -C /usr/share/icons/
        rm -f "$CURSOR_ARCHIVE"
        info "Deepin dark cursor theme installed."
    else
        rm -f "$CURSOR_ARCHIVE"
        warn "Could not download Deepin dark cursor theme from ${ICONS_BASE_URL}/cursor/"
    fi

    # Update the icon cache so the new themes are picked up immediately.
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        log "Updating icon cache..."
        for dir in /usr/share/icons/*/; do
            if [[ -f "${dir}/index.theme" ]]; then
                gtk-update-icon-cache -f -t "$dir" 2>/dev/null || true
            fi
        done
        info "Icon cache updated."
    fi
fi

set_phase 2
gauge_msg 65 "Enabling $DM_SERVICE..."
log "Enabling $DM_SERVICE..."

# --- Enable the display manager ---
#
# `systemctl enable` is supposed to work in a chroot (it only creates
# symlinks), but on a fresh chroot it can return 0 while silently NOT
# creating the alias symlink (bus/dbus checks, unit-loading quirks).
# Without /etc/systemd/system/display-manager.service the graphical
# target has nothing to start and the system drops to a TTY login
# prompt -- exactly the symptom we are fixing here. So: try systemctl
# first, then verify the symlink and create it by hand if needed.
if ! systemctl enable "$DM_SERVICE" 2>>"$LOG_FILE"; then
    warn "systemctl enable $DM_SERVICE failed -- will create the link manually."
fi

DM_UNIT="/usr/lib/systemd/system/${DM_SERVICE}"
DM_LINK="/etc/systemd/system/display-manager.service"
if [[ -f "$DM_UNIT" ]]; then
    if [[ ! -e "$DM_LINK" ]]; then
        log "Creating $DM_LINK -> $DM_UNIT manually."
        ln -sf "$DM_UNIT" "$DM_LINK"
    fi
else
    warn "Display manager unit $DM_UNIT not found -- cannot enable the DM."
fi

# --- Set graphical.target as the default boot target ---
#
# Same reasoning as above: without /etc/systemd/system/default.target
# pointing at graphical.target, systemd boots multi-user.target (a TTY
# login) even though the DM is enabled.
log "Setting graphical.target as the default boot target..."
if ! systemctl set-default graphical.target 2>>"$LOG_FILE"; then
    warn "systemctl set-default failed -- will create the link manually."
fi

DEFAULT_LINK="/etc/systemd/system/default.target"
DEFAULT_TARGET="/usr/lib/systemd/system/graphical.target"
if [[ -f "$DEFAULT_TARGET" ]]; then
    if [[ ! -L "$DEFAULT_LINK" || "$(readlink -f "$DEFAULT_LINK" 2>/dev/null)" != "$DEFAULT_TARGET" ]]; then
        log "Ensuring $DEFAULT_LINK -> $DEFAULT_TARGET."
        ln -sf "$DEFAULT_TARGET" "$DEFAULT_LINK"
    fi
fi

# --- Loud warning if either link is still missing after the fix ---
if [[ ! -e "$DM_LINK" ]]; then
    warn "display-manager.service is still missing -- the DM will not start at boot."
fi
if [[ "$(readlink -f "$DEFAULT_LINK" 2>/dev/null)" != "$DEFAULT_TARGET" ]]; then
    warn "default.target does not point to graphical.target -- boot may stay on a TTY."
fi

# ---------------- GNOME: DARK THEME + SLATE ACCENT + REGIONAL FORMATS ----------------

set_phase 3
if [[ "$DE_CHOICE" == "1" ]]; then
    gauge_msg 75 "Configuring GNOME theme for $TARGET_USER..."
    log "Setting GNOME dark theme + slate accent for $TARGET_USER..."

    # Apply per-user gsettings FIRST, using a temporary dbus session as the
    # target user. This works inside a chroot too: arch-chroot bind-mounts
    # /proc, /sys and /dev, and dbus-run-session creates its own session
    # socket under /tmp, so a session bus can start without a running
    # systemd user instance.
    #
    # This is the ONLY reliable way to set org.gnome.system.locale region:
    # GNOME treats it as a per-user preference and ignores the system-wide
    # dconf default for that key (unlike color-scheme / icon-theme, which
    # GNOME DOES read from /etc/dconf/db/local). Skipping this step is why
    # "Formats" stayed on the LANG default and never moved to CROAT.
    _user_gsettings_ok=0
    if command -v dbus-run-session >/dev/null 2>&1; then
        _user_gsettings_ok=1

        # Run every gsettings call in a single session so dbus starts once.
        if ! runuser -u "$TARGET_USER" -- dbus-run-session -- bash -s <<'GSETTINGS_EOF'
set -e
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' 2>/dev/null || true
gsettings set org.gnome.desktop.interface accent-color 'slate' 2>/dev/null || true
gsettings set org.gnome.desktop.interface clock-format '24h'
gsettings set org.gtk.Settings.FileChooser sort-directories-first true 2>/dev/null || true
gsettings set org.gnome.shell always-show-log-out true 2>/dev/null || true
gsettings set org.gnome.desktop.interface icon-theme 'Reversal' 2>/dev/null || true
gsettings set org.gnome.desktop.interface cursor-theme 'DeppinDark-cursors' 2>/dev/null || true
GSETTINGS_EOF
        then
            _user_gsettings_ok=0
            warn "Per-user gsettings failed -- falling back to system-wide dconf defaults."
        fi

        # Regional formats -- a separate setting, and the important one here.
        if [[ -n "$FORMAT_LOCALE" && "$_user_gsettings_ok" -eq 1 ]]; then
            if runuser -u "$TARGET_USER" -- dbus-run-session -- \
                    gsettings set org.gnome.system.locale region "$FORMAT_LOCALE"; then
                info "GNOME regional formats set per-user to $FORMAT_LOCALE."
            else
                warn "Could not set GNOME regional formats to $FORMAT_LOCALE per-user."
            fi
        fi
    else
        warn "dbus-run-session not found (package: dbus) -- per-user gsettings unavailable."
    fi

    # System-wide dconf defaults as a fallback, and to cover the keys GNOME
    # DOES read from /etc/dconf/db/local (color-scheme, gtk-theme,
    # icon-theme, cursor-theme, always-show-log-out). Writing them here is
    # idempotent even when the per-user path above succeeded.
    mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
    cat > /etc/dconf/profile/user <<'DCONF_PROFILE_EOF'
user-db:user
system-db:local
DCONF_PROFILE_EOF
    cat > /etc/dconf/db/local.d/00-arch-defaults <<'DCONF_EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'
accent-color='slate'
icon-theme='Reversal'
cursor-theme='DeppinDark-cursors'
clock-format='24h'

[org/gtk/settings/file-chooser]
sort-directories-first=true

[org/gnome/shell]
always-show-log-out=true
DCONF_EOF

    # Regional formats also go into the system-wide defaults: on some
    # GNOME versions the key IS honoured from here, and it costs nothing
    # to set both. Per-user gsettings above is still the primary mechanism.
    if [[ -n "$FORMAT_LOCALE" ]]; then
        printf '\n[org/gnome/system/locale]\nregion=%s\n' "'${FORMAT_LOCALE}'" \
            >> /etc/dconf/db/local.d/00-arch-defaults
    fi

    if command -v dconf >/dev/null 2>&1; then
        dconf update || warn "dconf update failed -- GNOME defaults may not apply."
    else
        warn "dconf not found -- GNOME defaults were written but not compiled."
    fi

    if [[ "$_user_gsettings_ok" -eq 1 ]]; then
        info "GNOME dark theme + regional formats set (applies on first login)."
    else
        info "GNOME defaults installed system-wide (per-user gsettings not available)."
    fi
fi

# ---------------- KDE: BREEZE DARK + REGIONAL FORMATS ----------------
#
# Written as the target user's own config so KDE reads them on first
# login. Two files:
#
#   ~/.config/kdeglobals         -- Breeze Dark as the default look & feel
#   ~/.config/plasma-localerc    -- regional formats (dates/numbers/...)
#                                   independent of the UI language
#
# The files are created with the target user's ownership -- KDE refuses
# to read a user config file that is owned by root, which is why the
# plain "> file" redirect as root would not have worked.

if [[ "$DE_CHOICE" == "2" ]]; then
    gauge_msg 75 "Setting KDE defaults (Breeze Dark, formats)..."
    log "Configuring KDE defaults for $TARGET_USER..."

    _kde_config_dir="${TARGET_HOME}/.config"
    install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$_kde_config_dir"

    # Breeze Dark. Both keys are set: [KDE] LookAndFeelPackage is the
    # modern setting (Plasma 5.24+ / Plasma 6) and covers the whole desktop
    # (colours, widget style, splash, wallpaper); [General] ColorScheme is
    # the older fallback that still works for GTK/Toolkit apps. If a
    # kdeglobals already exists (shouldn't on a fresh install, but a re-run
    # of installDE.sh must stay idempotent), our block is merged in place
    # instead of overwriting other keys.
    _kdeglobals="${_kde_config_dir}/kdeglobals"
    touch "$_kdeglobals"

    if ! grep -q '^\[KDE\]' "$_kdeglobals"; then
        printf '\n[KDE]\n' >> "$_kdeglobals"
    fi
    if grep -q '^LookAndFeelPackage=' "$_kdeglobals"; then
        sed -i 's|^LookAndFeelPackage=.*|LookAndFeelPackage=org.kde.breezedark.desktop|' "$_kdeglobals"
    else
        sed -i '/^\[KDE\]/a LookAndFeelPackage=org.kde.breezedark.desktop' "$_kdeglobals"
    fi

    if ! grep -q '^\[General\]' "$_kdeglobals"; then
        printf '[General]\n' >> "$_kdeglobals"
    fi
    if grep -q '^ColorScheme=' "$_kdeglobals"; then
        sed -i 's|^ColorScheme=.*|ColorScheme=BreezeDark|' "$_kdeglobals"
    else
        sed -i '/^\[General\]/a ColorScheme=BreezeDark' "$_kdeglobals"
    fi
    chown "$TARGET_USER:$TARGET_GROUP" "$_kdeglobals"

    # Regional formats. KDE reads these from plasma-localerc and applies
    # them independently of the interface language (the same separation
    # GNOME exposes as Region & Language -> Formats).
    if [[ -n "$FORMAT_LOCALE" ]]; then
        cat > "${_kde_config_dir}/plasma-localerc" <<PLASMA_LOCALERC_EOF
[Formats]
LANG=${FORMAT_LOCALE}

[Translations]
LANGUAGE=${SYSTEM_LANG%%.*}
PLASMA_LOCALERC_EOF
        chown "$TARGET_USER:$TARGET_GROUP" "${_kde_config_dir}/plasma-localerc"
        info "KDE Breeze Dark + regional formats ($FORMAT_LOCALE) set for $TARGET_USER."
    else
        info "KDE Breeze Dark set for $TARGET_USER."
    fi
fi

# ---------------- XFCE: ADWAITA-DARK + PANEL CLOCK ----------------
#
# XFCE has no "apply these settings for a new user" mechanism that works
# from a chroot without a running session bus, so the settings are written
# as the target user's own xfconf channel files. XFCE reads them on first
# login and applies them without any extra step.
#
# Three files under ~/.config/xfce4/xfconf/xfce-perchannel-xml/:
#
#   xsettings.xml     -> GTK theme (Adwaita-dark) + Adwaita icons/cursor
#   xfwm4.xml         -> window manager theme. "Default" follows the GTK
#                        color scheme on XFCE 4.16+, so with Adwaita-dark
#                        set above the title bars come up dark as well.
#   xfce4-panel.xml   -> the panel layout, including the clock plugin
#                        configured as "Time, then date" with a 24-hour
#                        time (%H:%M) and a "12 Oct 2026"-style date
#                        (%d %b %Y).
#
# The panel file uses our own plugin IDs (1..7). XFCE accepts them as the
# initial configuration -- it doesn't need the IDs to match some built-in
# scheme, it just reads whatever is in the file. This is the only way to
# preconfigure a clock plugin, because XFCE otherwise assigns the IDs at
# first login and we'd have no way to target the right one.
#
# Adwaita-dark ships inside the gtk3 package (XFCE pulls gtk3 in as a
# dependency), so no extra package is needed. Regional formats are handled
# at the system level via LC_TIME in /etc/locale.conf -- XFCE inherits it,
# so the date string renders in Croatian once hr_HR.UTF-8 is the LC_TIME.

if [[ "$DE_CHOICE" == "3" ]]; then
    gauge_msg 75 "Setting XFCE defaults (Adwaita-dark, panel clock)..."
    log "Configuring XFCE defaults for $TARGET_USER..."

    _xfce_conf_dir="${TARGET_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
    install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$_xfce_conf_dir"

    cat > "${_xfce_conf_dir}/xsettings.xml" <<'XSETTINGS_EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="CursorThemeSize" type="int" value="24"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Sans 10"/>
    <property name="MonospaceFontName" type="string" value="Monospace 10"/>
  </property>
</channel>
XSETTINGS_EOF

    cat > "${_xfce_conf_dir}/xfwm4.xml" <<'XFWM4_EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default"/>
    <property name="title_font" type="string" value="Sans Bold 10"/>
    <property name="title_alignment" type="string" value="center"/>
  </property>
</channel>
XFWM4_EOF

    cat > "${_xfce_conf_dir}/xfce4-panel.xml" <<'PANEL_EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="30"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
        <value type="int" value="7"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="launcher">
      <property name="items" type="array"/>
    </property>
    <property name="plugin-3" type="string" value="tasklist">
      <property name="grouping" type="uint" value="1"/>
      <property name="show-labels" type="bool" value="false"/>
    </property>
    <property name="plugin-4" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-5" type="string" value="systray">
      <property name="known-legacy-items" type="array"/>
    </property>
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-layout" type="uint" value="3"/>
      <property name="digital-time-format" type="string" value="%H:%M"/>
      <property name="digital-date-format" type="string" value="%d %b %Y"/>
    </property>
    <property name="plugin-7" type="string" value="showdesktop"/>
  </property>
</channel>
PANEL_EOF

    chown "$TARGET_USER:$TARGET_GROUP" \
        "${_xfce_conf_dir}/xsettings.xml" \
        "${_xfce_conf_dir}/xfwm4.xml" \
        "${_xfce_conf_dir}/xfce4-panel.xml"
    info "XFCE Adwaita-dark theme + 24h clock panel set for $TARGET_USER."
fi
# ---------------- BLUETOOTH (GNOME, full KDE) ----------------

if [[ "$DE_CHOICE" == "1" || ( "$DE_CHOICE" == "2" && "$INSTALL_MODE" == "full" ) ]]; then
    log "Enabling Bluetooth service and auto-enable policy..."

    # Enable and start the bluetooth systemd service.
    if unit_exists bluetooth.service; then
        systemctl enable bluetooth.service
        info "bluetooth.service enabled (will start on next boot)."
    else
        warn "bluetooth.service not found -- is the bluez package installed?"
    fi

    # Ensure the Bluetooth adapter is automatically powered on after
    # boot. By default BlueZ leaves the adapter soft-blocked, so even
    # with the service running, the GNOME toggle would stay off until
    # the user manually turns it on. AutoEnable=true makes the adapter
    # come up powered and discoverable-ready at boot.
    BLUETOOTH_MAIN_CONF="/etc/bluetooth/main.conf"
    if [[ -f "$BLUETOOTH_MAIN_CONF" ]]; then
        if grep -qE '^[[:space:]]*AutoEnable=' "$BLUETOOTH_MAIN_CONF"; then
            sed -i -E 's/^[[:space:]]*AutoEnable=.*/AutoEnable=true/' "$BLUETOOTH_MAIN_CONF"
        elif grep -qE '^\[Policy\]' "$BLUETOOTH_MAIN_CONF"; then
            # Insert AutoEnable=true right after the [Policy] header.
            sed -i '/^\[Policy\]/a AutoEnable=true' "$BLUETOOTH_MAIN_CONF"
        else
            # No [Policy] section found -- append one.
            printf '\n[Policy]\nAutoEnable=true\n' >> "$BLUETOOTH_MAIN_CONF"
        fi
        info "Bluetooth AutoEnable=true set in $BLUETOOTH_MAIN_CONF."
    else
        warn "$BLUETOOTH_MAIN_CONF not found -- Bluetooth adapter may need manual enabling after boot."
    fi
fi

# ---------------- GNOME: POWER PROFILES ----------------

if [[ "$DE_CHOICE" == "1" ]]; then
    if unit_exists power-profiles-daemon.service; then
        log "Enabling power-profiles-daemon (needed for Settings -> Power)..."
        systemctl enable power-profiles-daemon.service
    else
        warn "power-profiles-daemon.service not found -- Power settings may not work."
    fi
fi

# ---------------- LIGHTDM GREETER (XFCE) ----------------

if [[ "$DE_CHOICE" == "3" ]]; then
    if [[ -f /etc/lightdm/lightdm.conf ]]; then
        log "Setting lightdm-gtk-greeter as the LightDM greeter..."
        if grep -q '^greeter-session=' /etc/lightdm/lightdm.conf; then
            sed -i 's/^greeter-session=.*/greeter-session=lightdm-gtk-greeter/' /etc/lightdm/lightdm.conf
        elif grep -q '^\[Seat:\*\]' /etc/lightdm/lightdm.conf; then
            sed -i '/^\[Seat:\*\]/a greeter-session=lightdm-gtk-greeter' /etc/lightdm/lightdm.conf
        else
            printf '\n[Seat:*]\ngreeter-session=lightdm-gtk-greeter\n' >> /etc/lightdm/lightdm.conf
        fi
    else
        warn "/etc/lightdm/lightdm.conf not found -- LightDM may not start correctly without a greeter set."
    fi
fi

# ---------------- DONE ----------------

set_phase 4
gauge_msg 100 "Desktop environment installed."

log "Desktop environment install complete."

echo
echo "============================================================"
echo " NEXT STEPS"
echo "============================================================"
echo "Log out and back in (or reboot) to get to the $DM_SERVICE login screen."
if [[ "$DE_CHOICE" == "1" ]]; then
    echo "GNOME dark theme was pre-set -- it should already be dark on first login."
fi
if [[ "$DE_CHOICE" == "2" ]]; then
    echo "KDE Breeze Dark was pre-set -- it should already be applied on first login."
fi
if [[ "$DE_CHOICE" == "3" ]]; then
    echo "XFCE defaults were pre-set for first login:"
    echo "  - Adwaita-dark GTK theme + Adwaita icons/cursor"
    echo "  - Dark window decorations (Default xfwm4 follows the GTK scheme)"
    echo "  - Panel clock: Time then Date, 24h (%H:%M), date '%d %b %Y'"
    echo "LightDM greeter was set to lightdm-gtk-greeter; if the login screen"
    echo "looks wrong, check /etc/lightdm/lightdm.conf's [Seat:*] line."
fi
echo "============================================================"

# Restore stdout in interactive mode so the caller sees a clean pipe.
if (( INTERACTIVE )); then
    exec 1>&3
    exec 3>&-
fi
}

if (( INTERACTIVE )); then
    run_with_gauge "Installing $DE_NAME" "$LOG_FILE" run_de_install
    if [[ "$RUN_GAUGE_RC" -ne 0 ]]; then
        msg_box "Installation FAILED" "The desktop environment install did not finish.\n\nSee the log for details:\n  $LOG_FILE"
        exit 1
    fi

    # Show accumulated warnings in the final dialog so "theme failed to
    # download", "package skipped" etc. don't get lost in the log file.
    _warn_tail=""
    if [[ "${#WARN_LIST[@]}" -gt 0 ]]; then
        _warn_tail="\n\nWarnings:\n"
        for _w in "${WARN_LIST[@]}"; do
            _warn_tail+="  [!] $_w\n"
        done
    fi

    msg_box "Desktop installed" "$DE_NAME was installed.${_warn_tail}\n\nLog out and back in (or reboot) to reach the $DM_SERVICE login screen."
else
    run_de_install
fi
