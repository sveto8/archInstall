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
# progress in a dialog box. Full output is also saved to a log file.
#
# Official-repo packages are installed with plain pacman; anything
# not in the official repos goes through yay (AUR). yay is only
# bootstrapped (via pacman + makepkg) to handle that AUR subset.
# ============================================================

BACKTITLE="Arch Linux: application install"
LOG_FILE="${HOME}/installApps.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    _url="https://raw.githubusercontent.com/sveto8/archInstall/main/lib.sh"
    _code="$(curl -sSL -o "$SCRIPT_DIR/lib.sh.tmp" -w '%{http_code}' "$_url" 2>/dev/null || true)"
    if [[ "$_code" == "200" ]]; then
        mv "$SCRIPT_DIR/lib.sh.tmp" "$SCRIPT_DIR/lib.sh"
    else
        rm -f "$SCRIPT_DIR/lib.sh.tmp"
        echo "ERROR: lib.sh is missing next to $0 and could not be downloaded." >&2
        echo "       URL: $_url  (HTTP ${_code:-000}; 404 = not pushed to the repo, 000 = no network)" >&2
        echo "       Put lib.sh in the same folder as this script and run it again." >&2
        exit 1
    fi
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

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

# Background keepalive: refresh the sudo timestamp every ~30 seconds so
# long AUR builds (which can easily exceed sudo's default 15-minute
# timeout) don't trigger a password prompt in the middle of the install
# -- that prompt would corrupt the dialog --gauge display and stall the
# whole run. IMPORTANT: use `sudo -n -v` (explicitly updates the
# timestamp) rather than `sudo -n true` (which only checks it on some
# sudo builds and does NOT extend the timeout).
#
# The loop exits when either the parent shell dies (kill -0 $$) or a
# refresh fails -- it also writes the failure into $LOG_FILE so the
# install summary can report it.
(
    while kill -0 "$$" 2>/dev/null; do
        sleep 30
        if ! sudo -n -v 2>/dev/null; then
            echo "$(date): sudo keepalive: timestamp refresh failed" >> "$LOG_FILE"
            exit 0
        fi
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
#
# Every package is listed on its own line so the whole list is visible
# inside the dialog (a single long "foo bar baz" line used to be clipped).

WORK_TEXT="Install the work-related programs?\n\n"
WORK_TEXT+="Official repos (pacman):\n"
for _p in "${WORK_REPO[@]}"; do
    WORK_TEXT+="  - $_p\n"
done
WORK_TEXT+="\nAUR (yay):\n"
for _p in "${WORK_AUR[@]}"; do
    WORK_TEXT+="  - $_p\n"
done

if ask_yes "Work programs" "$WORK_TEXT" no; then
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

dlg --title "Confirm" --no-collapse --cr-wrap --yesno "$SUMMARY" 0 "$BOX_W" || abort

# ---------------- INSTALL HELPERS ----------------
#
# All sudo calls during the install use `-n` (non-interactive). Rationale:
# sudo writes its password prompt directly to /dev/tty, bypassing the
# stderr redirect that run_with_gauge applies. If the timestamp somehow
# expires mid-install, a normal `sudo pacman ...` would spray a prompt
# over the --gauge dialog (see: the "Sorry, try again" corruption).
# With `-n`, sudo fails cleanly instead -- the failed package is logged
# and reported in the summary, and the rest of the install continues.

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
    if ! sudo -n pacman -S --needed --noconfirm --noprogressbar "$pkg"; then
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

# run_install -- driven by run_with_gauge()
#
# Prints dialog --gauge frames on stdout (with a phase checklist + the
# current message + a percentage); every command's output is redirected
# to $LOG_FILE so the bar stays clean. The gauge percentage is computed
# from the total number of work items (base-devel + yay + every chosen
# package) so the bar fills steadily instead of jumping.
#
# NOTE: the body is deliberately not indented -- we keep the same
# style as the other scripts in this repository.

run_install() {
    local total current=0 pkg yay_tmp
    local log="$LOG_FILE"

    # ---- Phase checklist shown inside the gauge prompt ----
    local -a PHASES=(
        "Build tools (base-devel, git, yay)"
        "Official-repo packages"
        "AUR packages"
        "Extra packages"
        "Post-install tweaks (Java, CUPS)"
        "Done"
    )
    local CURRENT_PHASE=0

    _phase_prompt() {
        local i out=""
        for ((i=0; i<${#PHASES[@]}; i++)); do
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

    gauge_msg() {
        local pct="$1" msg="$2"
        {
            printf 'XXX\n%d\n' "$pct"
            _phase_prompt
            printf '\n%s\n' "$msg"
            printf 'XXX\n'
        }
    }
    set_phase() { CURRENT_PHASE="$1"; }

    total=$(( 2 + ${#REPO_PACKAGES[@]} + ${#AUR_PACKAGES[@]} + ${#EXTRA_PACKAGES[@]} ))
    if (( total < 1 )); then total=1; fi

    # ---- bootstrap yay ----
    set_phase 0
    gauge_msg $((current * 100 / total)) "Preparing build tools (base-devel, git)..."
    if ! sudo -n pacman -S --needed --noconfirm --noprogressbar base-devel git >> "$log" 2>&1; then
        warn "Failed to install base-devel/git -- sudo timestamp may have expired."
        echo "base-devel git" >> "$FAILED_FILE"
    fi
    current=$((current + 1))

    if ! command -v yay >/dev/null 2>&1; then
        gauge_msg $((current * 100 / total)) "Building yay from AUR (this can take a while)..."
        yay_tmp="$(mktemp -d)"
        git clone https://aur.archlinux.org/yay.git "$yay_tmp/yay" >> "$log" 2>&1
        ( cd "$yay_tmp/yay" && makepkg -si --noconfirm ) >> "$log" 2>&1
        rm -rf "$yay_tmp"
    fi
    current=$((current + 1))

    # ---- official repos ----
    set_phase 1
    for pkg in "${REPO_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] Installing $pkg (pacman)..."
        install_repo "$pkg" >> "$log" 2>&1
    done

    # ---- AUR ----
    set_phase 2
    for pkg in "${AUR_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] Installing $pkg (AUR)..."
        install_aur "$pkg" >> "$log" 2>&1
    done

    # ---- extras ----
    set_phase 3
    if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
        for pkg in "${EXTRA_PACKAGES[@]}"; do
            current=$((current + 1))
            gauge_msg $((current * 100 / total)) "[$current/$total] Installing $pkg..."
            if ! package_exists "$pkg"; then
                echo "$pkg" >> "$SKIPPED_FILE"
                continue
            fi
            if pacman -Si "$pkg" >/dev/null 2>&1; then
                install_repo "$pkg" >> "$log" 2>&1
            else
                install_aur "$pkg" >> "$log" 2>&1
            fi
        done
    fi

    # ---- default Java ----
    set_phase 4
    if [[ -d /usr/lib/jvm/java-11-openjdk ]]; then
        if [[ "$(archlinux-java get 2>/dev/null)" != "java-11-openjdk" ]]; then
            gauge_msg 99 "Setting OpenJDK 11 as the default JVM..."
            sudo -n archlinux-java set java-11-openjdk >> "$log" 2>&1 || \
                warn "Could not set default Java (sudo may have timed out)."
        fi
    fi

    # ---- printing ----
    gauge_msg 99 "Enabling CUPS (printing)..."
    sudo -n systemctl enable --now cups.service >> "$log" 2>&1 || \
        warn "Could not enable CUPS (sudo may have timed out)."

    set_phase 5
    gauge_msg 100 "Done."
}

# ---------------- RUN INSTALL (progress bar in a dialog box) ----------------

# Re-verify sudo is still cached right before entering the dialog: if the
# timestamp expired between the initial `sudo -v` and now, we want to
# re-authenticate BEFORE the dialog opens, not in the middle of it.
if ! sudo -n -v 2>/dev/null; then
    clear
    log "Re-authenticating sudo before the install begins..."
    sudo -v || die "sudo access is required."
fi

run_with_gauge "Installing applications" "$LOG_FILE" run_install

if [[ "$RUN_GAUGE_RC" -ne 0 ]]; then
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
        RESULT+="(If the failure was a sudo timeout, re-run this script; the second run will skip already-installed packages.)\n"
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

dlg --clear --title "App install complete" --no-collapse --cr-wrap --msgbox "$RESULT" 0 "$BOX_W"

clear
log "App install complete. Log: $LOG_FILE"
