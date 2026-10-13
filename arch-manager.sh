#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Arch Linux Installation Manager  (dialog menu)
#
# Downloads the installer scripts (+ lib.sh) from the repository and runs
# them. On the live ISO start with option 1; after the first reboot start
# it again (it is copied to /archInstall/) and use options 2-4 or 5.
#
# The menu is state-aware: entries that don't apply to the current
# system (e.g. "Install Arch" when Arch is already installed, or any
# of the post-install steps when running from the live ISO) are shown
# with an [N/A -- reason] prefix. dialog has no native "disabled" flag,
# so selecting an N/A entry shows a short explanation instead of running
# anything.
# ============================================================

# URL for the scripts repository. Override without editing the file:
#   ARCH_REPO_URL=https://raw.githubusercontent.com/<user>/<repo>/<branch> ./arch-manager.sh
# (lib.sh uses the very same variable, so every script follows the fork.)
SCRIPT_URL="${ARCH_REPO_URL:-https://raw.githubusercontent.com/sveto8/archInstall/main}"

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
    _code="$(curl -fsSL -o "$_lib_tmp" -w '%{http_code}' "${SCRIPT_URL}/lib.sh" 2>/dev/null || true)"
    if [[ -s "$_lib_tmp" ]]; then
        if mv "$_lib_tmp" "$SCRIPT_DIR/lib.sh" 2>/dev/null; then
            LIB="$SCRIPT_DIR/lib.sh"
        else
            LIB="${TMPDIR:-/tmp}/archInstall-lib.sh"
            mv "$_lib_tmp" "$LIB"
            echo "NOTE: $SCRIPT_DIR is not writable; using $LIB instead." >&2
        fi
    else
        rm -f "$_lib_tmp"
        echo "ERROR: lib.sh is missing next to $0 and could not be downloaded." >&2
        echo "       URL: ${SCRIPT_URL}/lib.sh  (HTTP ${_code:-000}; 404 = not pushed to the repo, 000 = no network)" >&2
        echo "       Put lib.sh (and the other scripts) in the same folder as arch-manager.sh and run it again." >&2
        exit 1
    fi
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

# ---------------- STATE DETECTION ----------------

# Prints the installed desktop environment (GNOME / KDE Plasma / XFCE),
# or nothing and returns 1 if none is found. Detection is by package
# presence, which works on any system regardless of the current session.
de_name() {
    if pacman -Qq gnome-shell    >/dev/null 2>&1; then echo "GNOME";       return 0; fi
    if pacman -Qq plasma-desktop >/dev/null 2>&1; then echo "KDE Plasma";  return 0; fi
    if pacman -Qq xfce4-session  >/dev/null 2>&1; then echo "XFCE";        return 0; fi
    return 1
}

de_installed() { de_name >/dev/null 2>&1; }

# ---------------- STATUS ----------------

status_text() {
    local arch="no" live="no" root="no" btrfs="no" snapper="no" desktop="none"
    [[ -f /etc/os-release ]] && grep -qE '^ID=("?)arch\1$' /etc/os-release && arch="yes"
    is_live_iso && live="yes"
    [[ $EUID -eq 0 ]] && root="yes"
    if command -v findmnt >/dev/null && [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" == "btrfs" ]]; then
        btrfs="yes"
    fi
    [[ -f /etc/snapper/configs/root ]] && snapper="yes"
    desktop="$(de_name || echo none)"

    printf 'System status:\n  Arch: %s   Live ISO: %s   Root: %s\n  Btrfs: %s   Snapper: %s   Desktop: %s\n\nChoose an action:' \
        "$arch" "$live" "$root" "$btrfs" "$snapper" "$desktop"
}

# ---------------- DOWNLOADING ----------------

download_single_script() {
    local script="$1"
    local dest="${DOWNLOAD_DIR}/${script}"
    local url="${SCRIPT_URL}/${script}"
    local tmp="${dest}.tmp" code

    printf '  Downloading %s ... ' "$script"
    code="$(curl -sSL -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
        mv "$tmp" "$dest"
        chmod +x "$dest"
        if [[ $EUID -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
            chown "$REAL_USER:$REAL_USER" "$dest" 2>/dev/null || true
        fi
        echo "OK"
        return 0
    fi
    rm -f "$tmp"     # never keep an HTML error page as a "script"
    case "${code:-000}" in
        404) echo "FAIL (HTTP 404 -- not in the repo: $url)" ;;
        000) echo "FAIL (no network / DNS problem: $url)" ;;
        *)   echo "FAIL (HTTP $code: $url)" ;;
    esac
    return 1
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

# Uses LOCAL copies before going to the network: scripts lying next to the
# manager (e.g. copied from a USB stick), in a scripts/ folder next to it, or
# the ones archInstall.sh placed on the installed system (/archInstall/scripts).
seed_from_local() {
    local d s
    for d in "$SCRIPT_DIR" "$SCRIPT_DIR/scripts" /archInstall/scripts; do
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
# callers never trip over "set -e"). Exit code 130 means "cancelled by
# the user" -- see abort() in lib.sh.
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
        # Every script already shows its OWN completion dialog when it
        # finishes successfully (setupAfterInstall.sh -> "Setup complete",
        # installDE.sh -> "Desktop installed", installApps.sh -> "App
        # install complete"). A second generic "completed successfully"
        # from the manager would just be a duplicate, so skip it.
        return 0
    elif [[ "$RUN_SCRIPT_RC" -eq 130 ]]; then
        msg_box "$script" "$script was cancelled -- nothing was changed."
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
        # A cancel in any dialog means the user chose to stop -- do NOT
        # continue with the remaining steps and do not report success.
        if [[ "$RUN_SCRIPT_RC" -eq 130 ]]; then
            msg_box "$script" "$script was cancelled -- stopping the remaining steps."
            return 0
        fi
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

    local choice items _de
    while true; do
        # Build the menu entries dynamically. The tag numbers stay the
        # same in every state (1..6), so the user builds muscle memory --
        # only the descriptions change. Entries that are not available in
        # the current state get an "[N/A -- reason]" prefix; dialog has no
        # native disabled flag for --menu items, so the prefix is the
        # visual cue, and selecting one lands in the case branch below
        # which shows an explanation instead of running anything.
        _de="$(de_name || true)"
        items=()

        if is_live_iso; then
            items+=(
                1 "Install Arch (archInstall.sh)"
                2 "[N/A -- live ISO only installs Arch] Setup Snapper/GRUB"
                3 "[N/A -- live ISO only installs Arch] Install desktop environment"
                4 "[N/A -- live ISO only installs Arch] Install applications"
                5 "[N/A -- live ISO only installs Arch] INSTALL ALL after reboot"
                6 "Download / update scripts"
            )
        else
            items+=(
                1 "[N/A -- Arch is already installed] Install Arch"
                2 "Setup Snapper/GRUB (setupAfterInstall.sh)"
            )
            if [[ -n "$_de" ]]; then
                items+=(3 "Reinstall / change desktop environment (currently $_de)")
            else
                items+=(3 "Install desktop environment (installDE.sh)")
            fi
            items+=(
                4 "Install applications (installApps.sh)"
                5 "INSTALL ALL after reboot (2 -> 3 -> 4)"
                6 "Download / update scripts"
            )
        fi

        choice="$(dlg_capture --title "Arch Linux Installation Manager" \
            --cancel-label "Exit" --no-collapse --cr-wrap \
            --menu "$(status_text)" 0 "$BOX_W" 0 "${items[@]}")" \
            || { clear; echo "Goodbye!"; exit 0; }

        case "$choice" in
            1)
                if ! is_live_iso; then
                    msg_box "Arch is already installed" \
"Option 1 runs archInstall.sh, which WIPES a whole disk and is meant
to be run only from the Arch live ISO.

The system you are on already has Arch installed.

  - To configure Snapper/GRUB, use option 2.
  - To install or replace the desktop environment, use option 3.
  - To install applications, use option 4."
                    continue
                fi

                run_script "archInstall.sh"
                case "$RUN_SCRIPT_RC" in
                    0)
                        clear
                        echo "Installation phase completed. Reboot into your new system when ready,"
                        echo "then run: sudo /archInstall/arch-manager.sh"
                        exit 0
                        ;;
                    130)
                        # User cancelled in one of the installer dialogs --
                        # return to the menu, don't claim success.
                        continue
                        ;;
                    *)
                        msg_box "archInstall.sh" "archInstall.sh did not finish successfully (exit code $RUN_SCRIPT_RC).\n\nDo NOT reboot yet. Check the errors, fix them and run it again."
                        exit 0
                        ;;
                esac
                ;;
            2)
                if is_live_iso; then
                    msg_box "Not available on the live ISO" \
"setupAfterInstall.sh configures the installed system (Snapper,
GRUB, Plymouth, Btrfs snapshots). It cannot touch the live ISO,
which runs entirely from RAM.

First install Arch (option 1), reboot into the new system, then
start the manager again and pick option 2."
                    continue
                fi
                run_script "setupAfterInstall.sh"; report_result "setupAfterInstall.sh"
                ;;
            3)
                if is_live_iso; then
                    msg_box "Not available on the live ISO" \
"The desktop environment is installed as the final step of option 1
(Install Arch), which offers GNOME / KDE Plasma / XFCE during the
installation.

If you skipped it during install, reboot into the new system first,
then start the manager again and pick option 3."
                    continue
                fi
                run_script "installDE.sh"; report_result "installDE.sh"
                ;;
            4)
                if is_live_iso; then
                    msg_box "Not available on the live ISO" \
"installApps.sh installs applications on the installed system.

It cannot run on the live ISO: makepkg and yay refuse to run as
root, and you are root on the live ISO by definition.

First install Arch (option 1), reboot into the new system, then
start the manager again and pick option 4."
                    continue
                fi
                run_script "installApps.sh"; report_result "installApps.sh"
                ;;
            5)
                if is_live_iso; then
                    msg_box "Not available on the live ISO" \
"INSTALL ALL runs setupAfterInstall.sh, installDE.sh and
installApps.sh in sequence.

All three need an installed Arch system to operate on -- none of
them can run on the live ISO, which is entirely in RAM.

First install Arch (option 1), reboot into the new system, then
start the manager again and pick option 5."
                    continue
                fi
                install_remaining
                ;;
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
            ensure_dialog
            ui_init
            download_all
            run_script "archInstall.sh"
            exit "$RUN_SCRIPT_RC"
            ;;
        --help) echo "Usage: $0 [--download|--install|--help|<script.sh>]"; exit 0 ;;
        *)
            ensure_dialog
            ui_init
            seed_from_local
            if in_array "$1" "${SCRIPTS[@]}" || [[ -f "${DOWNLOAD_DIR}/$1" ]]; then
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
