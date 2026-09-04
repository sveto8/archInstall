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
# Installs GNOME, KDE Plasma, or Hyprland (full or minimal package
# set), enables the matching display manager, and -- for Hyprland --
# writes a default hyprland.lua config (keybinds, waybar, hyprlock,
# hypridle) into the target user's home directory.
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
# The Hyprland config (and, for convenience, general desktop defaults)
# get written into a real user's home, not root's. Default to the
# first UID >= 1000 human account if there is exactly one; otherwise ask.

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
echo "  3) Hyprland (Wayland)"
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

# Common Wayland packages for all DEs (portals, qt support, etc.)
WAYLAND_COMMON=(
    xdg-desktop-portal
    xdg-desktop-portal-gtk
    qt5-wayland
    qt6-wayland
    polkit
    polkit-gnome
)

case "$DE_CHOICE" in
    1)
        DE_NAME="GNOME ($INSTALL_MODE) [Wayland]"
        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                gnome-shell
                gnome-session
                gnome-control-center
                gnome-tweaks
                nautilus
                gnome-terminal
                gdm
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
        DE_NAME="Hyprland ($INSTALL_MODE)"

        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                # --- Hyprland ---
                hyprland
                hyprpaper
                hyprpicker
                hyprlock
                hypridle

                # --- Desktop / UI ---
                waybar
                rofi-wayland

                # --- Terminal / file manager ---
                kitty
                thunar
                thunar-archive-plugin
                thunar-volman

                # --- Network ---
                network-manager-applet

                # --- Audio ---
                pipewire
                pipewire-alsa
                pipewire-pulse
                wireplumber
                pavucontrol

                # --- Wayland / portals ---
                xdg-desktop-portal
                xdg-desktop-portal-hyprland
                xdg-desktop-portal-gtk
                qt5-wayland
                qt6-wayland

                # --- Authentication / permissions ---
                polkit
                polkit-gnome

                # --- Notifications / clipboard ---
                mako
                wl-clipboard

                # --- Screenshots / brightness ---
                grim
                slurp
                brightnessctl

                # --- Bluetooth ---
                blueman

                # --- Media keys ---
                playerctl

                # --- Fonts ---
                ttf-dejavu
                ttf-liberation
                noto-fonts
                noto-fonts-emoji

                # --- XDG user directories ---
                xdg-user-dirs

                # --- Login manager ---
                sddm
            )
        else
            DE_PACKAGES=(
                hyprland
                hyprpaper
                hyprlock
                hypridle
                waybar
                rofi-wayland
                kitty
                thunar
                network-manager-applet
                pipewire
                pipewire-pulse
                wireplumber
                pavucontrol
                xdg-desktop-portal
                xdg-desktop-portal-hyprland
                xdg-desktop-portal-gtk
                qt5-wayland
                qt6-wayland
                polkit
                polkit-gnome
                mako
                wl-clipboard
                grim
                slurp
                brightnessctl
                noto-fonts
                noto-fonts-emoji
                xdg-user-dirs
                sddm
            )
        fi

        DM_SERVICE="sddm.service"
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

# ---------------- GNOME: DARK THEME BY DEFAULT ----------------

if [[ "$DE_CHOICE" == "1" ]]; then
    log "Setting GNOME to dark theme by default for $TARGET_USER..."

    if command -v dbus-run-session >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' \
            || warn "Could not set GNOME color-scheme to prefer-dark."
        runuser -u "$TARGET_USER" -- dbus-run-session -- \
            gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' \
            || warn "Could not set GNOME gtk-theme to Adwaita-dark (older GTK3 apps)."
        info "GNOME dark theme set (applies on first login)."
    else
        warn "dbus-run-session not found (package: dbus) -- skipping GNOME dark theme."
        info "Set it manually after login: Settings -> Appearance -> Dark."
    fi
fi

# ---------------- HYPRLAND CONFIG ----------------

if [[ "$DE_CHOICE" == "3" ]]; then
    log "Writing default Hyprland config for $TARGET_USER..."

    HYPR_USER="$TARGET_USER"
    HYPR_HOME="$TARGET_HOME"

    install -d -m 0755 -o "$HYPR_USER" -g "$HYPR_USER" \
        "$HYPR_HOME/.config/hypr" \
        "$HYPR_HOME/.config/waybar" \
        "$HYPR_HOME/.config/rofi" \
        "$HYPR_HOME/.config/hypridle" \
        "$HYPR_HOME/.config/hyprlock"

    cat > "$HYPR_HOME/.config/hypr/hyprland.lua" <<'HYPRLUA_EOF'
-- ============================================================
-- Hyprland default configuration
-- Generated by installDE.sh
-- Hyprland 0.55+ / Lua configuration
-- ============================================================

-- ------------------------------------------------------------
-- Monitor
-- ------------------------------------------------------------
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = "auto",
})

-- ------------------------------------------------------------
-- Programs
-- ------------------------------------------------------------
local terminal = "kitty"
local fileManager = "thunar"
local launcher = "rofi -show drun"

-- ------------------------------------------------------------
-- Environment
-- ------------------------------------------------------------
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")

-- ------------------------------------------------------------
-- Look & Feel
-- ------------------------------------------------------------
hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 12,
        border_size = 2,
        resize_on_border = false,
        allow_tearing = false,
        layout = "dwindle",
        col = {
            active_border = {
                colors = { "rgba(7aa2f7ff)", "rgba(bb9af7ff)" },
                angle = 45,
            },
            inactive_border = "rgba(565f89aa)",
        },
    },

    decoration = {
        rounding = 8,
        rounding_power = 2,

        active_opacity = 1.0,
        inactive_opacity = 0.96,

        shadow = {
            enabled = true,
            range = 6,
            render_power = 3,
            color = 0xee000000,
        },

        blur = {
            enabled = true,
            size = 4,
            passes = 2,
            vibrancy = 0.15,
        },
    },

    input = {
        kb_layout = "us",
        kb_variant = "",
        kb_model = "",
        kb_options = "",
        kb_rules = "",
        follow_mouse = 1,
        sensitivity = 0,
        touchpad = {
            natural_scroll = false,
        },
    },

    dwindle = {
        preserve_split = true,
    },

    misc = {
        force_default_wallpaper = -1,
        disable_hyprland_logo = false,
    },
})

-- ------------------------------------------------------------
-- Animations
-- ------------------------------------------------------------
hl.config({
    animations = {
        enabled = true,
    },
})

-- ------------------------------------------------------------
-- Keybindings
-- ------------------------------------------------------------
local mainMod = "SUPER"

hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(launcher))
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))

-- Close / fullscreen / float
hl.bind(mainMod .. " + C", hl.dsp.window.kill())
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mainMod .. " + SPACE", hl.dsp.window.float())

-- Reload / exit
hl.bind(mainMod .. " + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"))
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd("hyprctl dispatch exit"))

-- Focus
hl.bind(mainMod .. " + LEFT", hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + RIGHT", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + UP", hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + DOWN", hl.dsp.focus({ direction = "down" }))

-- Move window
hl.bind(mainMod .. " + SHIFT + LEFT", hl.dsp.window.move({ direction = "left" }))
hl.bind(mainMod .. " + SHIFT + RIGHT", hl.dsp.window.move({ direction = "right" }))
hl.bind(mainMod .. " + SHIFT + UP", hl.dsp.window.move({ direction = "up" }))
hl.bind(mainMod .. " + SHIFT + DOWN", hl.dsp.window.move({ direction = "down" }))

-- Resize / move with mouse
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Workspaces 1-10 (workspace 10 maps to physical key "0")
for i = 1, 10 do
    local key = i % 10
    hl.bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- Workspace scrolling
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

-- ------------------------------------------------------------
-- Audio keys
-- ------------------------------------------------------------
hl.bind("XF86AudioRaiseVolume",
    hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"),
    { locked = true, repeating = true })

hl.bind("XF86AudioLowerVolume",
    hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),
    { locked = true, repeating = true })

hl.bind("XF86AudioMute",
    hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
    { locked = true })

-- ------------------------------------------------------------
-- Brightness keys
-- ------------------------------------------------------------
hl.bind("XF86MonBrightnessUp",
    hl.dsp.exec_cmd("brightnessctl set 5%+"),
    { locked = true, repeating = true })

hl.bind("XF86MonBrightnessDown",
    hl.dsp.exec_cmd("brightnessctl set 5%-"),
    { locked = true, repeating = true })

-- ------------------------------------------------------------
-- Screenshot
-- ------------------------------------------------------------
hl.bind("PRINT", hl.dsp.exec_cmd(
    "grim -g \"$(slurp)\" ~/Pictures/Screenshots/$(date +%Y-%m-%d_%H-%M-%S).png"
))

-- ------------------------------------------------------------
-- Media keys
-- ------------------------------------------------------------
hl.bind("XF86AudioPlay",
    hl.dsp.exec_cmd("playerctl play-pause"),
    { locked = true })

hl.bind("XF86AudioNext",
    hl.dsp.exec_cmd("playerctl next"),
    { locked = true })

hl.bind("XF86AudioPrev",
    hl.dsp.exec_cmd("playerctl previous"),
    { locked = true })
HYPRLUA_EOF

    cat > "$HYPR_HOME/.config/waybar/config.jsonc" <<'WAYBAR_EOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,

    "modules-left": [
        "hyprland/workspaces"
    ],

    "modules-center": [
        "clock"
    ],

    "modules-right": [
        "network",
        "pulseaudio",
        "battery",
        "tray"
    ],

    "hyprland/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "on-click": "activate"
    },

    "clock": {
        "format": "{:%Y-%m-%d  %H:%M}",
        "tooltip-format": "{:%A, %d %B %Y}"
    },

    "network": {
        "format-wifi": "  {essid}",
        "format-ethernet": "󰈀  {ipaddr}",
        "format-disconnected": "󰤮  Disconnected",
        "tooltip-format": "{ifname}: {ipaddr}"
    },

    "pulseaudio": {
        "format": "  {volume}%",
        "format-muted": "  Muted",
        "on-click": "pavucontrol"
    },

    "battery": {
        "format": "  {capacity}%",
        "format-charging": "  {capacity}%"
    },

    "tray": {
        "spacing": 8
    }
}
WAYBAR_EOF

    cat > "$HYPR_HOME/.config/waybar/style.css" <<'WAYBAR_CSS_EOF'
* {
    font-family: "Noto Sans", sans-serif;
    font-size: 13px;
}

window#waybar {
    background: rgba(17, 19, 24, 0.92);
    color: #c0caf5;
}

#workspaces button {
    padding: 0 8px;
    color: #7982a9;
    background: transparent;
    border: none;
}

#workspaces button.active {
    color: #7aa2f7;
}

#clock,
#network,
#pulseaudio,
#battery,
#tray {
    padding: 0 10px;
}
WAYBAR_CSS_EOF

    cat > "$HYPR_HOME/.config/hypr/hyprlock.conf" <<'HYPRLOCK_EOF'
background {
    monitor =
    color = rgba(17, 19, 24, 1.0)
}

input-field {
    monitor =
    size = 250, 50
    outline_thickness = 2
    dots_size = 0.2
    dots_spacing = 0.2
    dots_center = true
    outer_color = rgba(122, 162, 247, 1.0)
    inner_color = rgba(31, 35, 48, 1.0)
    font_color = rgba(192, 202, 245, 1.0)
    fade_on_empty = false
    placeholder_text = <i>Password...</i>
    hide_input = false
    position = 0, -80
    halign = center
    valign = center
}

label {
    monitor =
    text = cmd[update:1000] echo "$(date '+%A, %d %B %Y  %H:%M')"
    color = rgba(192, 202, 245, 1.0)
    font_size = 28
    position = 0, 80
    halign = center
    valign = center
}
HYPRLOCK_EOF

    cat > "$HYPR_HOME/.config/hypr/hypridle.conf" <<'HYPRIDLE_EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 600
    on-timeout = loginctl lock-session
}

listener {
    timeout = 900
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
HYPRIDLE_EOF

    cat >> "$HYPR_HOME/.config/hypr/hyprland.lua" <<'HYPRIDLE_AUTOSTART_EOF'

-- Start idle management.
hl.on("hyprland.start", function()
    hl.exec_cmd("hypridle")
end)
HYPRIDLE_AUTOSTART_EOF

    install -d -m 0755 -o "$HYPR_USER" -g "$HYPR_USER" \
        "$HYPR_HOME/Pictures/Screenshots"

    if command -v xdg-user-dirs-update >/dev/null 2>&1; then
        runuser -u "$HYPR_USER" -- xdg-user-dirs-update || true
    fi

    chown -R "$HYPR_USER:$HYPR_USER" "$HYPR_HOME/.config" 2>/dev/null || true

    info "Hyprland default configuration installed for $HYPR_USER."
    info "Config: $HYPR_HOME/.config/hypr/hyprland.lua"
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
    echo "Hyprland config: $HYPR_HOME/.config/hypr/hyprland.lua"
    echo "Review it against https://github.com/hyprwm/Hyprland/blob/main/example/hyprland.lua"
    echo "before relying on it -- it's a starting point, not a finished setup."
fi
echo "============================================================"
