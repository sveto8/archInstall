#!/usr/bin/env bash
# ============================================================
# lib.sh -- shared helpers for the Arch install scripts.
#
# This file is SOURCED by archInstall.sh, setupAfterInstall.sh,
# installDE.sh, installApps.sh and arch-manager.sh -- it is not
# meant to be run directly. Keep it next to the scripts (the
# scripts download it automatically if it is missing).
# ============================================================

[[ -n "${ARCH_LIB_LOADED:-}" ]] && return 0
ARCH_LIB_LOADED=1

REPO_RAW_URL="https://raw.githubusercontent.com/sveto8/archInstall/main"

# ---------------- CONSOLE MESSAGES ----------------
#
# Colour is used only when the output is a real terminal. Inside a
# dialog --programbox the output is a pipe, so the very same functions
# print plain text there (dialog can't render ANSI colour codes).

WARN_LIST=()    # warnings collected so confirmation dialogs can show them

log() {
    if [[ -t 1 ]]; then printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
    else printf '\n[+] %s\n' "$*"; fi
}
info() {
    if [[ -t 1 ]]; then printf '\033[1;36m    %s\033[0m\n' "$*"
    else printf '    %s\n' "$*"; fi
}
warn() {
    WARN_LIST+=("$*")
    if [[ -t 1 ]]; then printf '\n\033[1;33m[!] %s\033[0m\n' "$*"
    else printf '\n[!] %s\n' "$*"; fi
}
error() {
    if [[ -t 2 ]]; then printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
    else printf '[ERROR] %s\n' "$*" >&2; fi
}
die() {
    if [[ -t 2 ]]; then printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
    else printf '\n[ERROR] %s\n' "$*" >&2; fi
    exit 1
}

in_array() {
    local needle="$1" e
    shift
    for e in "$@"; do
        [[ "$e" == "$needle" ]] && return 0
    done
    return 1
}

is_live_iso() {
    [[ -d /run/archiso ]] || { [[ -f /etc/os-release ]] && grep -q "ARCHISO" /etc/os-release; }
}

# Download a file from the scripts repository: fetch_repo_file <name> <dest>
fetch_repo_file() {
    curl -fsSL -o "$2" "${REPO_RAW_URL}/$1"
}

# ---------------- DIALOG SETUP ----------------

BACKTITLE="${BACKTITLE:-Arch Linux installer}"

# Installs dialog if missing. On the live ISO a database refresh (-Sy) is
# harmless (the system is throw-away); on an installed system a plain -S
# is used so we never do a partial upgrade.
ensure_dialog() {
    command -v dialog >/dev/null 2>&1 && return 0
    log "Installing 'dialog' (needed for the menus)..."
    if [[ $EUID -eq 0 ]]; then
        if is_live_iso; then pacman -Sy --noconfirm --needed dialog
        else pacman -S --noconfirm --needed dialog; fi
    else
        sudo pacman -S --noconfirm --needed dialog
    fi
    command -v dialog >/dev/null 2>&1 || die "Could not install 'dialog'. Check your internet connection."
}

# Compute box sizes from the terminal size.
ui_init() {
    TERM_LINES="$(tput lines 2>/dev/null || echo 24)"
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
    [[ "$TERM_LINES" =~ ^[0-9]+$ && "$TERM_LINES" -ge 20 ]] || TERM_LINES=24
    [[ "$TERM_COLS"  =~ ^[0-9]+$ && "$TERM_COLS"  -ge 60 ]] || TERM_COLS=80
    BOX_W=$(( TERM_COLS > 84 ? 80 : TERM_COLS - 4 ))
    LOG_H=$(( TERM_LINES - 4 ))
    LOG_W=$(( TERM_COLS - 4 ))
}

# Number of screen lines a text needs at the current box width (counts \n
# escapes / real newlines and estimates word wrapping).
_text_lines() {
    printf '%b' "$1" | awk -v w=$(( BOX_W - 6 )) '
        { l = length($0); n += (l == 0) ? 1 : int((l + w - 1) / w) }
        END { print n + 0 }'
}

# Box geometry for a --menu/--checklist with <n> items: the list gets exactly
# as many rows as there are items (so everything is visible at once and the
# box is no bigger than needed); only if that would not fit on the screen is
# the list capped and made scrollable.
#   _menu_geometry <text> <item_count>   -> sets MENU_H (box) and MENU_MH (list)
_menu_geometry() {
    local tl avail
    tl="$(_text_lines "$1")"
    avail=$(( TERM_LINES - tl - 7 ))
    (( avail < 3 )) && avail=3
    MENU_MH=$2
    (( MENU_MH > avail )) && MENU_MH=$avail
    (( MENU_MH < 1 )) && MENU_MH=1
    MENU_H=$(( tl + MENU_MH + 7 ))
}

# dialog wrapper. For --menu / --checklist / --radiolist the height and the
# list-height arguments the caller passes (normally 0 0) are replaced with
# values computed from the real item count -- passing 0 makes dialog show a
# big empty box with only a row or two of the list visible.
dlg() {
    local args=("$@") n=$# i kind="" per=2 count
    for ((i = 0; i < n; i++)); do
        case "${args[i]}" in
            --menu|--checklist|--radiolist) kind="${args[i]}"; break ;;
        esac
    done
    if [[ -n "$kind" ]]; then
        [[ "$kind" == "--menu" ]] || per=3
        # layout: <kind> TEXT HEIGHT WIDTH LIST-HEIGHT item...
        count=$(( (n - i - 5) / per ))
        _menu_geometry "${args[i+1]}" "$count"
        args[i+2]="$MENU_H"
        args[i+4]="$MENU_MH"
    fi
    dialog --backtitle "$BACKTITLE" "${args[@]}"
}

# Like dlg, but what the user selected/typed comes back on stdout
# (dialog itself writes results to stderr).
dlg_capture() { dlg "$@" 3>&1 1>&2 2>&3; }

# Leave cleanly (exit 0) when the user cancels a dialog.
abort() {
    clear
    echo "${1:-Cancelled -- nothing was changed.}"
    exit 0
}

# ---------------- DIALOG WIDGET HELPERS ----------------
# Text may contain \n; it is expanded by dialog.

# Height that fits a text (wrapped lines + frame/buttons), capped to the terminal.
_text_height() {
    local h
    h=$(( $(_text_lines "$1") + 8 ))
    (( h > TERM_LINES - 2 )) && h=$(( TERM_LINES - 2 ))
    printf '%s' "$h"
}

# ask_yes <title> <text> [yes|no]   -> returns 0 for Yes. 3rd arg = default.
ask_yes() {
    local opts=()
    [[ "${3:-yes}" == "no" ]] && opts+=(--defaultno)
    dlg --title "$1" --no-collapse --cr-wrap "${opts[@]}" \
        --yesno "$2" "$(_text_height "$2")" "$BOX_W"
}

# msg_box <title> <text>
msg_box() {
    dlg --title "$1" --no-collapse --cr-wrap \
        --msgbox "$2" "$(_text_height "$2")" "$BOX_W"
}

# ask_text <varname> <title> <text> [initial]  -> returns 1 on cancel/ESC
ask_text() {
    local __var="$1" out
    out="$(dlg_capture --title "$2" --no-collapse --cr-wrap \
        --inputbox "$3" "$(_text_height "$3")" "$BOX_W" "${4:-}")" || return 1
    printf -v "$__var" '%s' "$out"
}

# ask_password <varname> <title> -> asks twice, loops until they match.
# Returns 1 on cancel/ESC.
ask_password() {
    local __var="$1" title="$2" p1 p2
    while true; do
        p1="$(dlg_capture --title "$title" --insecure \
            --passwordbox "Enter password:" 9 "$BOX_W")" || return 1
        if [[ -z "$p1" ]]; then
            msg_box "$title" "The password can't be empty."
            continue
        fi
        p2="$(dlg_capture --title "$title" --insecure \
            --passwordbox "Repeat the password:" 9 "$BOX_W")" || return 1
        if [[ "$p1" == "$p2" ]]; then
            printf -v "$__var" '%s' "$p1"
            return 0
        fi
        msg_box "$title" "The passwords did not match -- try again."
    done
}

# run_in_box <title> <logfile> <function>
#
# Runs <function> with its output shown live in a dialog --programbox and
# appended to <logfile>. The result is returned in $RUN_RC (0 = the function
# ran to the end; 1 = a command inside it failed and aborted it). The
# function itself always returns 0.
#
# IMPORTANT: call it as a plain statement, then test $RUN_RC. Do NOT put
# the call in an if / && / || -- bash disables "set -e" for everything
# inside such a call, so a failing command would no longer abort the
# function.
#
# NOTE: the function runs in a subshell, so variables it sets are NOT
# visible afterwards -- report results via files if you need them.
RUN_RC=1
run_in_box() {
    local title="$1" logfile="$2" func="$3" ok_file had_e=0 had_pf=0
    RUN_RC=1
    ok_file="$(mktemp)"
    mkdir -p "$(dirname "$logfile")"
    { echo; echo "=== $(date): $title ==="; } >> "$logfile"

    # errexit must be genuinely ON inside the subshell. Putting the pipeline
    # in an "|| true" list would silently disable it for everything inside
    # (bash ignores -e in any command that is part of a || / && list), so
    # instead switch it off in the parent and back on explicitly inside.
    # pipefail is switched off too: otherwise a failing function would make
    # the whole pipeline "fail" and fire the caller's ERR trap.
    if [[ $- == *e* ]]; then had_e=1; fi
    if [[ "$SHELLOPTS" == *pipefail* ]]; then had_pf=1; fi
    set +e +o pipefail
    ( set -e; "$func"; echo ok > "$ok_file" ) 2>&1 | tee -a "$logfile" \
        | dlg --title "$title (press OK when finished)" \
              --programbox "Output is also saved to $logfile" \
              "$LOG_H" "$LOG_W"
    if (( had_pf )); then set -o pipefail; fi
    if (( had_e )); then set -e; fi
    if [[ -s "$ok_file" ]]; then RUN_RC=0; fi
    rm -f "$ok_file"
    clear
    return 0
}
