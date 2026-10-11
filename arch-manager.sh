#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Arch Linux Installation Manager  (dialog menu)
#
# Downloads the installer scripts (+ lib.sh) from the repository and runs
# them. On the live ISO start with option 1; after the first reboot start
# it again (it is copied to /archInstall/) and use options 2-4 or 5.
# ============================================================

# URL for the scripts repository (change according to your repo)
SCRIPT_URL="https://raw.githubusercontent.com/sveto8/archInstall/main"

# Everything the manager downloads (lib.sh is sourced by the others).
SCRIPTS=(
    "lib.sh"
    "archInstall.sh"
    "setupAfterInstall.sh"
    "installDE.sh"
    "installApps.sh"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib.sh"
if [[ ! -f "$LIB" && -f "$SCRIPT_DIR/scripts/lib.sh" ]]; then
    LIB="$SCRIPT_DIR/scripts/lib.sh"
fi
if [[ ! -f "$LIB" ]]; then
    curl -fsSL -o "$SCRIPT_DIR/lib.sh" "${SCRIPT_URL}/lib.sh" \
        || { echo "ERROR: lib.sh not found next to $0 and the download failed." >&2; exit 1; }
    LIB="$SCRIPT_DIR/lib.sh"
fi
# shellcheck source=lib.sh
source "$LIB"

BACKTITLE="Arch Linux Installation Manager"
LOG_FILE="${TMPDIR:-/tmp}/arch-manager.log"

# archInstall.sh uses this to find the manager when it copies it to the
# new system.
ARCH_MANAGER_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
export ARCH_MANAGER_PATH

REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$REAL_HOME" ]] || REAL_HOME="$HOME"

WORK_DIR="${REAL_HOME}/arch-setup"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
mkdir -p "$DOWNLOAD_DIR"

# If we ended up running as root (e.g. `sudo ./arch-manager.sh`), make sure
# the downloaded files are owned by the real user, not root, so
# installApps.sh (which must NOT run as root) can read/execute them.
fix_ownership() {
    if [[ $EUID -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
        chown -R "$REAL_USER:$REAL_USER" "$WORK_DIR" 2>/dev/null || true
    fi
}
fix_ownership

# ---------------- STATUS ----------------

status_text() {
    local arch="no" live="no" root="no" btrfs="no" snapper="no"
    [[ -f /etc/os-release ]] && grep -q "ID=arch" /etc/os-release && arch="yes"
    is_live_iso && live="yes"
    [[ $EUID -eq 0 ]] && root="yes"
    if command -v findmnt >/dev/null && [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" == "btrfs" ]]; then
        btrfs="yes"
    fi
    [[ -f /etc/snapper/configs/root ]] && snapper="yes"
    printf 'System status:\n  Arch: %s   Live ISO: %s   Root: %s\n  Btrfs: %s   Snapper: %s\n\nChoose an action:' \
        "$arch" "$live" "$root" "$btrfs" "$snapper"
}

de_installed() {
    local p
    for p in gnome-shell plasma-desktop xfce4-session; do
        if pacman -Qq "$p" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

# ---------------- DOWNLOADING ----------------

download_single_script() {
    local script="$1"
    local dest="${DOWNLOAD_DIR}/${script}"

    printf '  Downloading %s ... ' "$script"
    if curl -fsSL -o "$dest" "${SCRIPT_URL}/${script}"; then
        chmod +x "$dest"
        if [[ $EUID -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
            chown "$REAL_USER:$REAL_USER" "$dest" 2>/dev/null || true
        fi
        echo "OK"
        return 0
    else
        echo "FAIL"
        return 1
    fi
}

download_all() {
    log "Downloading all scripts..."
    local failed=0 script
    for script in "${SCRIPTS[@]}"; do
        download_single_script "$script" || failed=$((failed + 1))
    done
    fix_ownership
    [[ "$failed" -eq 0 ]] || die "$failed script(s) failed to download."
    log "All scripts downloaded successfully."
}

# Copies scripts that archInstall.sh placed on the installed system
# (/archInstall/scripts, or a scripts/ folder next to the manager) into the
# download folder, so they don't have to be fetched again.
seed_from_local() {
    local d s
    for d in "$SCRIPT_DIR/scripts" /archInstall/scripts; do
        [[ -d "$d" ]] || continue
        for s in "${SCRIPTS[@]}"; do
            if [[ ! -f "$DOWNLOAD_DIR/$s" && -f "$d/$s" ]]; then
                cp "$d/$s" "$DOWNLOAD_DIR/$s"
                chmod +x "$DOWNLOAD_DIR/$s"
            fi
        done
    done
    fix_ownership
}

# ---------------- RUNNING A SCRIPT ----------------
#
# Always returns 0; the script's exit code is left in RUN_SCRIPT_RC (so
# callers never trip over "set -e").
RUN_SCRIPT_RC=0

run_script() {
    local script="$1"
    local path="${DOWNLOAD_DIR}/${script}"
    local needs_root=false
    RUN_SCRIPT_RC=1

    seed_from_local

    # Download on demand (the script and lib.sh, which it sources).
    local need
    for need in "$script" "lib.sh"; do
        if [[ ! -f "${DOWNLOAD_DIR}/${need}" ]]; then
            echo "Downloading missing ${need} ..."
            if ! download_single_script "$need"; then
                fix_ownership
                msg_box "Download failed" "Could not download $need.\n\nCheck your internet connection and try again."
                return 0
            fi
        fi
    done
    fix_ownership

    case "$script" in
        archInstall.sh|setupAfterInstall.sh|installDE.sh) needs_root=true ;;
    esac

    clear
    local code=0
    if [[ "$needs_root" == true ]]; then
        if [[ $EUID -eq 0 ]]; then
            "$path" || code=$?
        elif command -v sudo >/dev/null 2>&1; then
            echo "$script needs root privileges -- running with sudo (enter your password)..."
            sudo "$path" || code=$?
        else
            msg_box "No sudo" "sudo is not installed -- run the manager as root."
            return 0
        fi
    else
        # installApps.sh must NOT run as root (makepkg/yay refuse). If the
        # manager itself is root (e.g. started with sudo), drop to the real user.
        if [[ $EUID -eq 0 ]]; then
            if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
                msg_box "Can't run as root" "installApps.sh must not run as root and there is no regular user to switch to.\n\nStart the manager as your normal user (not with sudo)."
                return 0
            fi
            runuser -u "$REAL_USER" -- "$path" || code=$?
        else
            "$path" || code=$?
        fi
    fi
    RUN_SCRIPT_RC=$code
    return 0
}

report_result() {
    local script="$1"
    if [[ "$RUN_SCRIPT_RC" -eq 0 ]]; then
        msg_box "$script" "$script completed successfully."
    else
        msg_box "$script" "$script FAILED (exit code $RUN_SCRIPT_RC).\n\nCheck the messages and log files, fix the problem and run it again."
    fi
}

# Runs setupAfterInstall -> installDE -> installApps (after reboot).
install_remaining() {
    local scripts_to_run=(setupAfterInstall.sh installDE.sh installApps.sh) script
    for script in "${scripts_to_run[@]}"; do
        if [[ "$script" == "installDE.sh" ]] && de_installed; then
            if ! ask_yes "Desktop environment" "A desktop environment is already installed (probably from archInstall.sh).\n\nInstall another one anyway?" no; then
                continue
            fi
        fi
        run_script "$script"
        report_result "$script"
        if [[ "$RUN_SCRIPT_RC" -ne 0 ]]; then
            ask_yes "Continue?" "$script failed.\n\nContinue with the remaining steps anyway?" no || return 0
        fi
    done
    msg_box "All done" "The remaining steps have finished."
}

# ---------------- MAIN MENU ----------------

main() {
    ensure_dialog
    ui_init

    local choice
    while true; do
        choice="$(dlg_capture --title "Arch Linux Installation Manager" \
            --cancel-label "Exit" --no-collapse --cr-wrap \
            --menu "$(status_text)" 0 "$BOX_W" 0 \
            1 "Install Arch (archInstall.sh)" \
            2 "Setup Snapper/GRUB (setupAfterInstall.sh)" \
            3 "Install desktop environment (installDE.sh)" \
            4 "Install applications (installApps.sh)" \
            5 "INSTALL ALL after reboot (2 -> 3 -> 4)" \
            6 "Download / update scripts")" || { clear; echo "Goodbye!"; exit 0; }

        case "$choice" in
            1)
                if ! is_live_iso; then
                    ask_yes "Not the live ISO" "This does not look like the Arch live ISO.\n\narchInstall.sh WIPES a whole disk and is meant to be run from the live ISO only.\n\nRun it anyway?" no || continue
                fi
                run_script "archInstall.sh"
                if [[ "$RUN_SCRIPT_RC" -eq 0 ]]; then
                    clear
                    echo "Installation phase completed. Reboot into your new system when ready,"
                    echo "then run: sudo /archInstall/arch-manager.sh"
                else
                    msg_box "archInstall.sh" "archInstall.sh did not finish successfully (exit code $RUN_SCRIPT_RC).\n\nDo NOT reboot yet. Check the errors, fix them and run it again."
                fi
                exit 0
                ;;
            2) run_script "setupAfterInstall.sh"; report_result "setupAfterInstall.sh" ;;
            3) run_script "installDE.sh";         report_result "installDE.sh" ;;
            4) run_script "installApps.sh";       report_result "installApps.sh" ;;
            5) install_remaining ;;
            6)
                run_in_box "Downloading scripts" "$LOG_FILE" download_all
                if [[ "$RUN_RC" -eq 0 ]]; then
                    msg_box "Download" "All scripts downloaded to:\n  $DOWNLOAD_DIR"
                else
                    msg_box "Download" "Some scripts failed to download -- check your internet connection."
                fi
                ;;
        esac
    done
}

# ---------------- COMMAND LINE ----------------

if [[ $# -gt 0 ]]; then
    case "$1" in
        --download) download_all; exit 0 ;;
        --install)
            # Live ISO: download everything and run archInstall.sh.
            download_all
            run_script "archInstall.sh"
            exit "$RUN_SCRIPT_RC"
            ;;
        --help) echo "Usage: $0 [--download|--install|--help|<script.sh>]"; exit 0 ;;
        *)
            if [[ -f "${DOWNLOAD_DIR}/$1" ]]; then
                run_script "$1"
                exit "$RUN_SCRIPT_RC"
            else
                error "Unknown option: $1"
                exit 1
            fi
            ;;
    esac
fi

main "$@"
