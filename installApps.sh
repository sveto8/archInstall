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

FAILED_FILE=""
SKIPPED_FILE=""
SUDO_KEEPALIVE_PID=""

cleanup() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    rm -f "$FAILED_FILE" "$SKIPPED_FILE"
    # Remove the sudoers drop-in we created, so sudo's timestamp_timeout
    # goes back to the system default for the user's future sessions.
    if [[ "${SUDOERS_DROPIN_CREATED:-0}" == "1" ]]; then
        sudo rm -f "$SUDOERS_DROPIN" 2>/dev/null || true
    fi
}

trap 'die "Failed at line $LINENO."' ERR
trap cleanup EXIT

# ---------------- BASIC CHECKS ----------------

[[ $EUID -ne 0 ]] || die "Run this as your regular user, not root/sudo (makepkg refuses to run as root)."

command -v pacman >/dev/null || die "pacman not found -- is this an Arch system?"

log "Checking sudo access (you may be asked for your password)..."
sudo -v || die "sudo access is required."

# ---------------- SUDO: ONE PROMPT ONLY ----------------
#
# yay and makepkg call sudo internally WITHOUT -n, so even though every
# sudo call we make ourselves uses -n, an expired timestamp would let
# them pop a password prompt right in the middle of the --gauge dialog
# (that is the "tosevjenajbolji:" prompt the user sees over the bar).
#
# Fix: raise sudo's timestamp_timeout to 2 hours via a short-lived
# sudoers drop-in (removed in cleanup). 2 hours covers any AUR build.
# Combined with the keepalive below, no sudo prompt can ever appear
# during the install.
SUDOERS_DROPIN="/etc/sudoers.d/99-installer-timestamp"
SUDOERS_DROPIN_CREATED=0
if [[ ! -e "$SUDOERS_DROPIN" ]]; then
    if printf 'Defaults timestamp_timeout=120\n' | sudo tee "$SUDOERS_DROPIN" >/dev/null 2>&1; then
        sudo chmod 440 "$SUDOERS_DROPIN" 2>/dev/null || true
        if sudo visudo -cf "$SUDOERS_DROPIN" >/dev/null 2>&1; then
            SUDOERS_DROPIN_CREATED=1
            info "Extended sudo timeout to 120 minutes for this session."
        else
            warn "Invalid sudoers drop-in; removing."
            sudo rm -f "$SUDOERS_DROPIN"
        fi
    else
        warn "Could not create sudoers drop-in -- keeping default timeout."
    fi
fi

# Refresh the timestamp now that the new timeout is active.
sudo -v 2>/dev/null || true

# Keepalive as a second line of defense: refresh every 30 s so the
# timestamp never gets close to expiring, even if the drop-in was not
# created (e.g. read-only /etc). Uses `sudo -n -v` (which explicitly
# EXTENDS the timestamp) rather than `sudo -n true` (which on some
# sudo builds only checks it).
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

# JDK used for work. Package + the name `archlinux-java` knows it by: change
# both here (e.g. jdk17-openjdk / java-17-openjdk) and nothing else.
JAVA_PKG="jdk11-openjdk"
JAVA_ENV="java-11-openjdk"

# Work-related packages (optional, asked separately)
WORK_REPO=(
    "$JAVA_PKG"
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
# OnlyOffice), which are OFF; LACT / CoolerControl depend on the hardware
# (see below). nautilus-admin-gtk4 is a Nautilus-specific
# AUR package ("Open as Administrator" in the context menu), so it is
# only offered when gnome-shell is detected.

NAUTILUS_ITEM=()
if pacman -Qq gnome-shell >/dev/null 2>&1; then
    NAUTILUS_ITEM=(nautilus-admin "Nautilus 'Open as Administrator' (AUR)" on)
fi

# Hardware-dependent defaults: LACT only makes sense with an AMD GPU, and
# CoolerControl (case fans / AIO) is a desktop thing. The same script can
# therefore be run on a desktop with a Radeon and on an Intel-graphics
# laptop and offer sensible defaults on both. Everything stays selectable.
GPU_VENDORS="$(detect_gpu_vendors)"
LACT_STATE="off"; LACT_NOTE=" -- no AMD GPU detected"
if [[ " $GPU_VENDORS " == *" amd "* ]]; then LACT_STATE="on"; LACT_NOTE=""; fi
COOLER_STATE="on"; COOLER_NOTE=""
if is_laptop; then COOLER_STATE="off"; COOLER_NOTE=" -- laptop detected"; fi

CHOICES="$(dlg_capture --title "Optional packages" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel." 0 "$BOX_W" 0 \
    lact           "Lact - AMD GPU control/overclock (pacman)${LACT_NOTE}" "$LACT_STATE" \
    coolercontrol  "CoolerControl - fan/cooling control (AUR)${COOLER_NOTE}" "$COOLER_STATE" \
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

ask_yes "Confirm" "$SUMMARY" yes || abort

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
    # --sudoflags "-n" makes yay pass -n to its internal sudo call, so
    # even if the timestamp somehow expires, yay's sudo fails cleanly
    # instead of prompting on /dev/tty over the --gauge dialog.
    if ! yay --sudoflags "-n" -S --needed --noconfirm "$pkg"; then
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

# The log lives in the user's own home, so the redirects performed by the
# (unprivileged) shell are exactly what we want -- not by sudo.
# shellcheck disable=SC2024
run_install() {
    local total current=0 pkg yay_tmp
    local log="$LOG_FILE"

    # ---- Phase tree shown inside the gauge prompt ----
    #
    # PHASE_NAMES is the static list of phases; CUR_PHASE is the 0-based
    # index of the phase currently running; CUR_ITEMS is the list of
    # packages/steps inside that phase; CUR_IDX is the index of the item
    # currently being processed. Only the CURRENT phase expands into its
    # sub-items -- the rest stay collapsed into one line each.
    local -a PHASE_NAMES=(
        "Build tools"
        "Official-repo packages"
        "AUR packages"
        "Extra packages"
        "Post-install tweaks"
        "Done"
    )
    local CUR_PHASE=0
    local -a CUR_ITEMS=()
    local CUR_IDX=0
    local WIN=5   # how many sub-items to show around the current one

    _phase_prompt() {
        local i j n start end out=""
        for ((i=0; i<${#PHASE_NAMES[@]}; i++)); do
            # Progress marker line -- see archInstall.sh for the rationale.
            if (( i == CUR_PHASE && CUR_PHASE > 0 )); then
                out+="$(printf '%*s' $(( BOX_W - 8 )) '' | tr ' ' '-')"$'\n'
            fi
            if (( i < CUR_PHASE )); then
                out+="  [✓] ${PHASE_NAMES[i]}"$'\n'
            elif (( i == CUR_PHASE )); then
                out+="  [>] ${PHASE_NAMES[i]}"$'\n'
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
                out+="  [ ] ${PHASE_NAMES[i]}"$'\n'
            fi
        done
        printf '%s' "$out"
    }

    gauge_msg() {
        local pct="$1" msg="$2"
        {
            printf 'XXX\n%d\n' "$pct"
            _phase_prompt
            printf '%s\n' "$msg"
            printf 'XXX\n'
        } >&3
    }

    total=$(( 2 + ${#REPO_PACKAGES[@]} + ${#AUR_PACKAGES[@]} + ${#EXTRA_PACKAGES[@]} ))
    if (( total < 1 )); then total=1; fi

    # ---- Phase 0: build tools (base-devel, git, yay) ----
    CUR_PHASE=0
    CUR_ITEMS=(base-devel git yay)
    CUR_IDX=0

    gauge_msg $((current * 100 / total)) "Installing base-devel, git..."
    if ! sudo -n pacman -S --needed --noconfirm --noprogressbar base-devel git >> "$log" 2>&1; then
        warn "Failed to install base-devel/git -- sudo timestamp may have expired." >> "$log"
        echo "base-devel git" >> "$FAILED_FILE"
    fi
    CUR_IDX=1
    current=$((current + 1))

    if ! command -v yay >/dev/null 2>&1; then
        gauge_msg $((current * 100 / total)) "Building yay from AUR (this can take a while)..."
        yay_tmp="$(mktemp -d)"
        git clone https://aur.archlinux.org/yay.git "$yay_tmp/yay" >> "$log" 2>&1
        # </dev/null: makepkg calls sudo internally; with no tty on stdin,
        # sudo cannot prompt and will fail immediately instead of spraying
        # a password prompt over the dialog.
        ( cd "$yay_tmp/yay" && makepkg -si --noconfirm </dev/null ) >> "$log" 2>&1
        rm -rf "$yay_tmp"
    fi
    CUR_IDX=2
    current=$((current + 1))

    # ---- Phase 1: official repos ----
    CUR_PHASE=1
    CUR_ITEMS=("${REPO_PACKAGES[@]}")
    CUR_IDX=0
    for pkg in "${REPO_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] $pkg (pacman)"
        install_repo "$pkg" >> "$log" 2>&1
        CUR_IDX=$((CUR_IDX + 1))
    done

    # ---- Phase 2: AUR ----
    CUR_PHASE=2
    CUR_ITEMS=("${AUR_PACKAGES[@]}")
    CUR_IDX=0
    for pkg in "${AUR_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] $pkg (AUR)"
        install_aur "$pkg" >> "$log" 2>&1
        CUR_IDX=$((CUR_IDX + 1))
    done

    # ---- Phase 3: extras ----
    CUR_PHASE=3
    if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
        CUR_ITEMS=("${EXTRA_PACKAGES[@]}")
        CUR_IDX=0
        for pkg in "${EXTRA_PACKAGES[@]}"; do
            current=$((current + 1))
            gauge_msg $((current * 100 / total)) "[$current/$total] $pkg"
            if ! package_exists "$pkg"; then
                echo "$pkg" >> "$SKIPPED_FILE"
            elif pacman -Si "$pkg" >/dev/null 2>&1; then
                install_repo "$pkg" >> "$log" 2>&1
            else
                install_aur "$pkg" >> "$log" 2>&1
            fi
            CUR_IDX=$((CUR_IDX + 1))
        done
    else
        CUR_ITEMS=()
    fi

    # ---- Phase 4: post-install tweaks ----
    CUR_PHASE=4
    CUR_ITEMS=("Java default" "CUPS enable")
    CUR_IDX=0

    if [[ -d "/usr/lib/jvm/${JAVA_ENV}" ]]; then
        if [[ "$(archlinux-java get 2>/dev/null)" != "$JAVA_ENV" ]]; then
            gauge_msg 99 "Setting ${JAVA_ENV} as the default JVM..."
            sudo -n archlinux-java set "$JAVA_ENV" >> "$log" 2>&1 || \
                warn "Could not set default Java (sudo may have timed out)." >> "$log"
        fi
    fi
    CUR_IDX=1

    gauge_msg 99 "Enabling CUPS (printing)..."
    sudo -n systemctl enable --now cups.service >> "$log" 2>&1 || \
        warn "Could not enable CUPS (sudo may have timed out)." >> "$log"
    CUR_IDX=2

    # ---- Phase 5: done ----
    CUR_PHASE=5
    CUR_ITEMS=()
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

# Taller gauge so the phase tree + sub-steps fit comfortably.
GAUGE_HEIGHT=22

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

msg_box "App install complete" "$RESULT"

clear
log "App install complete. Log: $LOG_FILE"
