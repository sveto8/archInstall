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

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
info() { printf '\033[1;36m    %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'die "Failed at line $LINENO."' ERR

# ---------------- BASIC CHECKS ----------------

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "This script needs root, and sudo isn't installed to elevate automatically. Run it with: su -c ./installDE.sh"
    echo "Not running as root -- re-launching with sudo (you may be asked for your password)."
    exec sudo -- "$0" "$@"
fi

command -v pacman >/dev/null || die "pacman not found -- is this an Arch system?"

# ---------------- TARGET USER ----------------
#
# Desktop-specific defaults (GNOME dark theme, etc.) get applied to a
# real user's home, not root's. Default to the first UID >= 1000 human
# account if there is exactly one; otherwise ask.

CANDIDATE_USERS=()
while IFS=: read -r uname _ uid _; do
    [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]] && CANDIDATE_USERS+=("$uname")
done < /etc/passwd

if [[ "${#CANDIDATE_USERS[@]}" -eq 1 ]]; then
    TARGET_USER="${CANDIDATE_USERS[0]}"
    info "Target user: $TARGET_USER"
else
    echo
    if [[ "${#CANDIDATE_USERS[@]}" -gt 1 ]]; then
        echo "Multiple regular users found: ${CANDIDATE_USERS[*]}"
    else
        warn "No regular (non-system) user found on this system."
    fi
    read -r -p "Username to configure the desktop environment for: " TARGET_USER
    id -u "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Could not determine home directory for $TARGET_USER."

# ---------------- DESKTOP ENVIRONMENT ----------------

echo
echo "Desktop environment:"
echo "  1) GNOME (Wayland)"
echo "  2) KDE Plasma (Wayland)"
echo "  3) XFCE (X11)"
echo "  4) None / cancel"
read -r -p "Choice [1]: " DE_CHOICE
DE_CHOICE="${DE_CHOICE:-1}"

[[ "$DE_CHOICE" == "4" ]] && { echo "Nothing to do."; exit 0; }

DE_PACKAGES=()
DM_SERVICE=""
INSTALL_MODE=""

if [[ "$DE_CHOICE" == "1" || "$DE_CHOICE" == "2" || "$DE_CHOICE" == "3" ]]; then
    read -r -p "Full install or minimal? [F/m]: " INSTALL_MODE
    [[ "$INSTALL_MODE" =~ ^[Mm]$ ]] && INSTALL_MODE="minimal" || INSTALL_MODE="full"
fi

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
            # Full GNOME = the two official Arch package groups plus gnome-tweaks.
            # DE_PACKAGES=(
            #     gnome                   # official package group -- full core desktop + stock GNOME apps
            #     gnome-extra             # official package group -- additional GNOME applications
            #     gnome-tweaks            # not part of either group but essential for tweaking GNOME
            #     "${WAYLAND_COMMON[@]}"
            # )
            DE_PACKAGES=(
                gnome                   # official package group -- full core desktop + stock GNOME apps
                # --- replacement for gnome-extra (excluding games) ---
                chatty                  # SMS and Matrix client
                d-spy                   # D-Bus debugger
                dconf-editor            # GSettings editor
                endeavour               # personal task manager (formerly GNOME Todo)
                ghex                    # hex editor
                gnome-boxes             # virtual machine manager
                gnome-builder           # IDE for GNOME apps
                gnome-calls             # phone and call manager
                gnome-sound-recorder    # simple sound recorder
                manuals                 # developer documentation browser
                sysprof                 # performance profiler
                power-profiles-daemon   # power profile settings in gnome-settings
                bluez                   # Bluetooth protocol stack
                bluez-utils             # provides bluetoothctl

                gnome-tweaks            # not part of either group but essential for tweaking GNOME
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
        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                plasma-desktop
                plasma-workspace-wayland
                dolphin
                konsole
                sddm
                "${WAYLAND_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                plasma-desktop
                plasma-workspace-wayland
                dolphin
                konsole
                sddm
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
                "${X11_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                xfce4
                lightdm
                lightdm-gtk-greeter
                "${X11_COMMON[@]}"
            )
        fi

        DM_SERVICE="lightdm.service"
        ;;
esac
info "Desktop environment: $DE_NAME"

# ---------------- CONFIRM ----------------

echo
echo "============================================================"
echo "Target user:  $TARGET_USER ($TARGET_HOME)"
echo "Desktop:      $DE_NAME"
echo "Packages:     ${DE_PACKAGES[*]}"
echo "============================================================"
read -r -p "Continue? [Y/n] " CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && { echo "Cancelled."; exit 0; }

# ---------------- INSTALL ----------------

log "Installing $DE_NAME packages..."

pacman -S --needed --noconfirm "${DE_PACKAGES[@]}"

# ---------------- ICONS & CURSORS (from GitHub) ----------------

ICONS_BASE_URL="https://raw.githubusercontent.com/sveto8/archInstall/main"

# Download and install icon theme (Reversal)
log "Downloading Reversal icon theme..."
ICON_ARCHIVE="/tmp/Reversal-icon-theme-master.tar.xz"
if curl -fsSL -o "$ICON_ARCHIVE" "${ICONS_BASE_URL}/icons/Reversal-icon-theme-master.tar.xz"; then
    log "Extracting Reversal icon theme to /usr/share/icons/..."
    tar -xf "$ICON_ARCHIVE" -C /usr/share/icons/
    rm -f "$ICON_ARCHIVE"
    info "Reversal icon theme installed."
else
    warn "Could not download Reversal icon theme from ${ICONS_BASE_URL}/icons/"
fi

# Download and install cursor theme (DeepinV20-dark)
log "Downloading Deepin-dark cursor theme..."
CURSOR_ARCHIVE="/tmp/DeppinDark-cursors.tar.xz"
if curl -fsSL -o "$CURSOR_ARCHIVE" "${ICONS_BASE_URL}/cursor/DeppinDark-cursors.tar.xz"; then
    log "Extracting DeepinV20-dark cursor theme to /usr/share/icons/..."
    tar -xf "$CURSOR_ARCHIVE" -C /usr/share/icons/
    rm -f "$CURSOR_ARCHIVE"
    info "DeepinV20-dark cursor theme installed."
else
    warn "Could not download DeepinV20-dark cursor theme from ${ICONS_BASE_URL}/cursor/"
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

log "Enabling $DM_SERVICE..."
systemctl enable "$DM_SERVICE"

# ---------------- GNOME: DARK THEME + SLATE ACCENT ----------------

if [[ "$DE_CHOICE" == "1" ]]; then
    log "Setting GNOME dark theme + slate accent for $TARGET_USER..."

    if command -v dbus-run-session >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' \
            || warn "Could not set GNOME color-scheme to prefer-dark."
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' \
            || warn "Could not set GNOME gtk-theme to Adwaita-dark (older GTK3 apps)."
        # Accent color is a GNOME 47+ feature. On older versions the key
        # doesn't exist and gsettings will error out -- that's fine, we
        # just warn and continue.
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gnome.desktop.interface accent-color 'slate' \
            || warn "Could not set GNOME accent-color to slate (requires GNOME 47+)."
        # Directories before files when browsing. This sets the GTK
        # FileChooser preference, which is the closest available option:
        # Nautilus 42+ removed the per-view "sort folders before files"
        # toggle from its own preferences, but this still affects GTK
        # file dialogs (open/save) system-wide.
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gtk.Settings.FileChooser sort-directories-first true \
            || warn "Could not set sort-directories-first for GTK file dialogs."
        # Apply the Reversal icon theme and DeepinV20-dark cursor theme
        # installed earlier by this script.
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gnome.desktop.interface icon-theme 'Reversal' \
            || warn "Could not set GNOME icon-theme to Reversal."
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gnome.desktop.interface cursor-theme 'DeepinV20-dark' \
            || warn "Could not set GNOME cursor-theme to DeepinV20-dark."
        info "GNOME dark theme + slate accent set (applies on first login)."
    else
        warn "dbus-run-session not found (package: dbus) -- skipping GNOME theme setup."
        info "Set it manually after login: Settings -> Appearance -> Dark + Slate."
    fi
fi

# ---------------- GNOME: BLUETOOTH ----------------

if [[ "$DE_CHOICE" == "1" ]]; then
    log "Enabling Bluetooth service and auto-enable policy..."

    # Enable and start the bluetooth systemd service.
    if systemctl list-unit-files bluetooth.service >/dev/null 2>&1; then
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
    if systemctl list-unit-files power-profiles-daemon.service >/dev/null 2>&1; then
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

log "Desktop environment install complete."

echo
echo "============================================================"
echo " NEXT STEPS"
echo "============================================================"
echo "Log out and back in (or reboot) to get to the $DM_SERVICE login screen."
if [[ "$DE_CHOICE" == "1" ]]; then
    echo "GNOME dark theme was pre-set -- it should already be dark on first login."
fi
if [[ "$DE_CHOICE" == "3" ]]; then
    echo "LightDM greeter was set to lightdm-gtk-greeter; if the login screen looks"
    echo "wrong, check /etc/lightdm/lightdm.conf's [Seat:*] greeter-session line."
fi
echo "============================================================"
