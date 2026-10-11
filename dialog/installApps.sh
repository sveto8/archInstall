#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: application install (Phase 2) -- dialog (ncurses) UI
#
# Run this as your REGULAR user (NOT root, NOT via sudo) after
# archInstall.sh + setupAfterInstall.sh have already been run.
# makepkg/yay refuse to run as root.
#
# Flow: ask everything up front (checklist / yes-no / input boxes),
# show a confirmation summary, then install unattended with live
# output in a dialog box. Full output is also saved to a log file.
#
# Official-repo packages are installed with plain pacman; anything
# not in the official repos goes through yay (AUR). yay is only
# bootstrapped (via pacman + makepkg) to handle that AUR subset.
# ============================================================

BACKTITLE="Arch Linux: application install"
LOG_FILE="${HOME}/installApps.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    curl -fsSL -o "$SCRIPT_DIR/lib.sh" "https://raw.githubusercontent.com/sveto8/archInstall/main/lib.sh" \
        || { echo "ERROR: lib.sh not found next to $0 and the download failed." >&2; exit 1; }
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Plain progress helpers used while the install runs inside the dialog box.
say()     { printf '%s\n' "$*"; }
section() { printf '\n===== %s =====\n' "$*"; }

FAILED_FILE=""
SKIPPED_FILE=""
SUDO_KEEPALIVE_PID=""

cleanup() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    rm -f "$FAILED_FILE" "$SKIPPED_FILE"
}

trap 'die "Failed at line $LINENO."' ERR
trap cleanup EXIT

# ---------------- BASIC CHECKS ----------------

[[ $EUID -ne 0 ]] || die "Run this as your regular user, not root/sudo (makepkg refuses to run as root)."

command -v pacman >/dev/null || die "pacman not found -- is this an Arch system?"

log "Checking sudo access (you may be asked for your password)..."
sudo -v || die "sudo access is required."

# Keep the sudo timestamp fresh: AUR builds can easily outlast sudo's
# default 15-minute timeout, and a password prompt in the middle of a
# dialog screen would garble the UI.
(
    while true; do
        sudo -n true 2>/dev/null || exit 0
        sleep 50
        kill -0 "$$" 2>/dev/null || exit 0
    done
) &
SUDO_KEEPALIVE_PID=$!

ensure_dialog

FAILED_FILE="$(mktemp)"
SKIPPED_FILE="$(mktemp)"

# ---------------- DIALOG SETUP ----------------

ui_init

# ---------------- PACKAGE LISTS ----------------
#
# REPO_PACKAGES -> plain pacman (official repos)
# AUR_PACKAGES  -> yay (not in official repos)
#
# Optional packages are chosen in the dialogs below.

# Base packages (always installed)
REPO_PACKAGES=(
    terminator
    guake
    qmmp
    kolourpaint
    mission-center
    stow
    hplip                               # HP printer support
    cups                                # printing system
    system-config-printer               # GUI printer management
    eza
)

AUR_PACKAGES=(
    google-chrome
    sublime-text-4
    peazip
    python-pyqt5                        # for hp-setup
)

# Work-related packages (optional, asked separately)
WORK_REPO=(
    jdk11-openjdk
    meld
    code                                # open-source VS Code
    remmina
)

WORK_AUR=(
    intellij-idea-community-edition
    postman-bin
    f5vpn-ng                            # F5 VPN client
    ferdium-bin                         # Ferdium messaging client
    snx-rs                              # VPN
)

# ---------------- DIALOG: OPTIONAL PACKAGES ----------------
#
# Defaults: everything ON except the office suites (LibreOffice, WPS,
# OnlyOffice), which are OFF. nautilus-admin-gtk4 is a Nautilus-specific
# AUR package ("Open as Administrator" in the context menu), so it is
# only offered when gnome-shell is detected.

NAUTILUS_ITEM=()
if pacman -Qq gnome-shell >/dev/null 2>&1; then
    NAUTILUS_ITEM=(nautilus-admin "Nautilus 'Open as Administrator' (AUR)" on)
fi

CHOICES="$(dlg_capture --title "Optional packages" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel." 0 "$BOX_W" 0 \
    lact           "Lact - AMD GPU control/overclock (pacman)" on \
    coolercontrol  "CoolerControl - fan/cooling control (AUR)" on \
    "${NAUTILUS_ITEM[@]}" \
    libreoffice    "LibreOffice still (pacman)" off \
    wps            "WPS Office + fonts (AUR)" off \
    onlyoffice     "OnlyOffice (AUR)" off)" || abort

while IFS= read -r tag; do
    case "$tag" in
        lact)            REPO_PACKAGES+=(lact) ;;
        coolercontrol)   AUR_PACKAGES+=(coolercontrol-bin) ;;
        nautilus-admin)  AUR_PACKAGES+=(nautilus-admin-gtk4) ;;
        libreoffice)     REPO_PACKAGES+=(libreoffice-still) ;;
        wps)             AUR_PACKAGES+=(wps-office ttf-wps-fonts) ;;
        onlyoffice)      AUR_PACKAGES+=(onlyoffice-bin) ;;
    esac
done <<< "$CHOICES"

# ---------------- DIALOG: WORK PROGRAMS (default: No) ----------------

WORK_TEXT="Install the work-related programs?\n\nRepo (pacman):\n  ${WORK_REPO[*]}\n\nAUR (yay):\n  ${WORK_AUR[*]}"

if dlg --title "Work programs" --defaultno --no-collapse \
       --yesno "$WORK_TEXT" 0 "$BOX_W"; then
    REPO_PACKAGES+=("${WORK_REPO[@]}")
    AUR_PACKAGES+=("${WORK_AUR[@]}")
fi

# ---------------- DIALOG: EXTRA PACKAGES ----------------

EXTRA_INPUT="$(dlg_capture --title "Extra packages" \
    --inputbox "Any extra packages to add? (space-separated, blank to skip)\n\nOfficial-repo and AUR names both work." \
    11 "$BOX_W")" || EXTRA_INPUT=""

EXTRA_PACKAGES=()
read -r -a EXTRA_PACKAGES <<< "$EXTRA_INPUT"

# ---------------- DIALOG: CONFIRMATION ----------------

SUMMARY="Repo (pacman):\n  ${REPO_PACKAGES[*]}\n\nAUR (yay):\n  ${AUR_PACKAGES[*]}\n\nExtra:\n  ${EXTRA_PACKAGES[*]:-none}\n\nProceed with the installation?"

dlg --title "Confirm" --no-collapse --yesno "$SUMMARY" 0 "$BOX_W" || abort

# ---------------- INSTALL HELPERS ----------------

# Checks whether a package name exists (official repo OR AUR) before we
# attempt to install it, so a typo/renamed/removed package is skipped
# with a clear message instead of failing mid-transaction.
package_exists() {
    local pkg="$1"
    pacman -Si "$pkg" >/dev/null 2>&1 && return 0
    yay -Si "$pkg" >/dev/null 2>&1 && return 0
    return 1
}

# Failures/skips go to files (not arrays) because the install runs in a
# pipeline subshell; arrays set there would be lost.
install_repo() {
    local pkg="$1"
    if ! pacman -Si "$pkg" >/dev/null 2>&1; then
        warn "$pkg not found in official repos -- skipping."
        echo "$pkg" >> "$SKIPPED_FILE"
        return 0
    fi
    if ! sudo pacman -S --needed --noconfirm --noprogressbar "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        echo "$pkg" >> "$FAILED_FILE"
    fi
}

install_aur() {
    local pkg="$1"
    if ! package_exists "$pkg"; then
        warn "$pkg not found (repo or AUR) -- skipping."
        echo "$pkg" >> "$SKIPPED_FILE"
        return 0
    fi
    if ! yay -S --needed --noconfirm "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        echo "$pkg" >> "$FAILED_FILE"
    fi
}

run_install() {
    # ---- bootstrap yay ----
    section "Preparing build tools"
    sudo pacman -S --needed --noconfirm --noprogressbar base-devel git

    if ! command -v yay >/dev/null 2>&1; then
        say "yay not found, building it from AUR..."
        local yay_tmp
        yay_tmp="$(mktemp -d)"
        git clone https://aur.archlinux.org/yay.git "$yay_tmp/yay"
        (cd "$yay_tmp/yay" && makepkg -si --noconfirm)
        rm -rf "$yay_tmp"
    else
        say "yay already installed."
    fi

    # ---- official repos ----
    section "Official-repo packages (pacman)"
    local pkg
    for pkg in "${REPO_PACKAGES[@]}"; do
        say ""
        say "==> $pkg"
        install_repo "$pkg"
    done

    # ---- AUR ----
    section "AUR packages (yay)"
    for pkg in "${AUR_PACKAGES[@]}"; do
        say ""
        say "==> $pkg"
        install_aur "$pkg"
    done

    # ---- extras ----
    if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
        section "Extra packages"
        for pkg in "${EXTRA_PACKAGES[@]}"; do
            say ""
            say "==> $pkg"
            if ! package_exists "$pkg"; then
                warn "$pkg does not exist in the official repos or AUR -- skipping (check the name)."
                echo "$pkg" >> "$SKIPPED_FILE"
                continue
            fi
            if pacman -Si "$pkg" >/dev/null 2>&1; then
                install_repo "$pkg"
            else
                install_aur "$pkg"
            fi
        done
    fi

    # ---- default Java ----
    section "OpenJDK 11"
    if [[ -d /usr/lib/jvm/java-11-openjdk ]]; then
        if [[ "$(archlinux-java get 2>/dev/null)" == "java-11-openjdk" ]]; then
            say "OpenJDK 11 is already the default JVM."
        else
            say "Setting OpenJDK 11 as the default JVM..."
            sudo archlinux-java set java-11-openjdk
            say "Default Java: $(archlinux-java get)"
        fi
    else
        warn "OpenJDK 11 is not installed (part of the work bundle)."
    fi

    # ---- printing ----
    section "CUPS (printing)"
    sudo systemctl enable --now cups.service

    section "Done"
}

# ---------------- RUN INSTALL (live output in a dialog box) ----------------

run_in_box "Installing applications" "$LOG_FILE" run_install

if [[ "$RUN_RC" -ne 0 ]]; then
    die "Installation stopped early -- see $LOG_FILE for details."
fi

# ---------------- SUMMARY ----------------

mapfile -t FAILED  < "$FAILED_FILE"
mapfile -t SKIPPED < "$SKIPPED_FILE"

RESULT=""
if [[ "${#FAILED[@]}" -eq 0 && "${#SKIPPED[@]}" -eq 0 ]]; then
    RESULT+="All packages installed successfully.\n"
else
    if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
        RESULT+="SKIPPED (package name not found):\n"
        for pkg in "${SKIPPED[@]}"; do
            RESULT+="  - $pkg\n"
        done
        RESULT+="\n"
    fi
    if [[ "${#FAILED[@]}" -gt 0 ]]; then
        RESULT+="FAILED (found, but install errored):\n"
        for pkg in "${FAILED[@]}"; do
            RESULT+="  - $pkg\n"
        done
        RESULT+="Re-run 'yay -S <package>' or 'sudo pacman -S <package>' individually to see the actual error.\n"
    fi
fi

RESULT+="\nManual steps still needed:\n"
if in_array snx-rs "${AUR_PACKAGES[@]}"; then
    RESULT+="  - snx-rs: takes a while to build from source, this is expected.\n"
fi
RESULT+="  - HP printer: run 'hp-setup' to detect/add your printer over the network or USB.\n"
if in_array f5vpn-ng "${AUR_PACKAGES[@]}"; then
    RESULT+="  - F5 VPN (f5vpn-ng): if it fails to build or launch, check the AUR comment page -- it tracks F5's client releases and occasionally needs a library fix (libxml2/webkit2gtk) after a system update.\n"
fi
RESULT+="\nFull log: $LOG_FILE"

dlg --title "App install complete" --no-collapse --msgbox "$RESULT" 0 "$BOX_W"

clear
log "App install complete. Log: $LOG_FILE"
