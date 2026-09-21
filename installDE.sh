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
# Installs GNOME, KDE Plasma, COSMIC, Budgie (Wayland), or XFCE, Cinnamon
# (X11 -- Wayland on both is still experimental/unstable upstream) --
# full or minimal package set -- and enables the matching display
# manager/greeter.
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
echo "  3) COSMIC (Wayland)"
echo "  4) Budgie (Wayland)"
echo "  5) XFCE (X11)"
echo "  6) Cinnamon (X11)"
echo "  7) None / cancel"
read -r -p "Choice [1]: " DE_CHOICE
DE_CHOICE="${DE_CHOICE:-1}"

[[ "$DE_CHOICE" == "7" ]] && { echo "Nothing to do."; exit 0; }

DE_PACKAGES=()
DM_SERVICE=""
INSTALL_MODE=""

if [[ "$DE_CHOICE" == "1" || "$DE_CHOICE" == "2" || "$DE_CHOICE" == "3" || "$DE_CHOICE" == "4" || "$DE_CHOICE" == "5" || "$DE_CHOICE" == "6" ]]; then
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

# Common X11 packages for XFCE/Cinnamon -- no qt-wayland/portal-wayland bits
# needed since these run on Xorg, not a Wayland compositor.
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
            DE_PACKAGES=(
                gnome                   # official package group -- full GNOME desktop (shell, session, gdm, nautilus, console, software, all core apps)
                gnome-extra             # official package group -- additional GNOME apps (evolution, boxes, builder, games, ...)
                gnome-tweaks            # not part of either group but required for tweaking the desktop
                "${WAYLAND_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                gnome-shell
                gnome-control-center
                nautilus
                gnome-terminal
                gdm
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
        DE_NAME="COSMIC ($INSTALL_MODE) [Wayland]"

        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                cosmic                  # official package group -- full desktop + all components
                packagekit              # needed for cosmic-store (App Center) to install packages
                power-profiles-daemon   # needed for Settings -> Power and Battery to work
                "${WAYLAND_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                cosmic-session
                cosmic-greeter
                cosmic-comp
                cosmic-panel
                cosmic-launcher
                cosmic-applets
                cosmic-bg
                cosmic-files
                cosmic-terminal
                cosmic-settings
                cosmic-settings-daemon
                cosmic-notifications
                cosmic-osd
                xdg-desktop-portal-cosmic
                power-profiles-daemon
                "${WAYLAND_COMMON[@]}"
            )
        fi

        DM_SERVICE="cosmic-greeter.service"
        ;;
    4)
        DE_NAME="Budgie ($INSTALL_MODE) [Wayland]"

        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                budgie                  # official package group -- all first-party components
                budgie-extras           # extra applets (Wiki: can alter existing behavior, but useful)
                lightdm
                lightdm-gtk-greeter
                nautilus                # Budgie ships no file manager by default
                gnome-terminal          # Budgie ships no terminal by default
                "${WAYLAND_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                budgie-desktop
                budgie-desktop-services
                budgie-control-center
                lightdm
                lightdm-gtk-greeter
                nautilus
                gnome-terminal
                "${WAYLAND_COMMON[@]}"
            )
        fi

        DM_SERVICE="lightdm.service"
        ;;
    5)
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
    6)
        DE_NAME="Cinnamon ($INSTALL_MODE) [X11]"

        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                cinnamon                # includes nemo (files), muffin (wm), cinnamon-session, etc.
                cinnamon-translations
                nemo-fileroller         # archive integration for the Nemo file manager
                gnome-terminal          # Cinnamon ships no terminal of its own
                blueberry               # Bluetooth settings
                lightdm
                lightdm-gtk-greeter
                "${X11_COMMON[@]}"
            )
        else
            DE_PACKAGES=(
                cinnamon
                gnome-terminal
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
read -r -p "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# ---------------- INSTALL ----------------

log "Installing $DE_NAME packages..."

pacman -S --needed --noconfirm "${DE_PACKAGES[@]}"

log "Enabling $DM_SERVICE..."
systemctl enable "$DM_SERVICE"

# ---------------- GNOME: DARK THEME + YELLOW ACCENT ----------------

if [[ "$DE_CHOICE" == "1" ]]; then
    log "Setting GNOME dark theme + yellow accent for $TARGET_USER..."

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
            gsettings set org.gnome.desktop.interface accent-color 'yellow' \
            || warn "Could not set GNOME accent-color to yellow (requires GNOME 47+)."
        info "GNOME dark theme + yellow accent set (applies on first login)."
    else
        warn "dbus-run-session not found (package: dbus) -- skipping GNOME theme setup."
        info "Set it manually after login: Settings -> Appearance -> Dark + Yellow."
    fi
fi

# ---------------- COSMIC: POWER PROFILES ----------------

if [[ "$DE_CHOICE" == "3" ]]; then
    if systemctl list-unit-files power-profiles-daemon.service >/dev/null 2>&1; then
        log "Enabling power-profiles-daemon (needed for Settings -> Power and Battery)..."
        systemctl enable power-profiles-daemon.service
    else
        warn "power-profiles-daemon.service not found -- Power and Battery settings may not work."
    fi
fi

# ---------------- LIGHTDM GREETER (Budgie / XFCE / Cinnamon) ----------------

if [[ "$DE_CHOICE" == "4" || "$DE_CHOICE" == "5" || "$DE_CHOICE" == "6" ]]; then
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
    echo "COSMIC is configured entirely through its own Settings app (no config file"
    echo "to hand-edit) -- keybinds, panel, wallpaper, etc. are all in there."
    if [[ "$INSTALL_MODE" == "full" ]]; then
        echo "cosmic-store (App Center) needs packagekit, which was installed above."
    fi
fi
if [[ "$DE_CHOICE" == "4" || "$DE_CHOICE" == "5" || "$DE_CHOICE" == "6" ]]; then
    echo "LightDM greeter was set to lightdm-gtk-greeter; if the login screen looks"
    echo "wrong, check /etc/lightdm/lightdm.conf's [Seat:*] greeter-session line."
fi
echo "============================================================"
