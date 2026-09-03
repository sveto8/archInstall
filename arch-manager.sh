#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Arch Linux Installation Manager
# ============================================================

# URL for the scripts repository (change according to your repo)
SCRIPT_URL="https://raw.githubusercontent.com/sveto8/archInstall/main"

# List of scripts
SCRIPTS=(
    "archInstall.sh"
    "setupAfterInstall.sh"
    "installDE.sh"
    "installApps.sh"
)

WORK_DIR="${HOME}/arch-setup"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
mkdir -p "$DOWNLOAD_DIR"

# ---------------- COLORS ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------- FUNCTIONS ----------------
log() { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}   $*${NC}"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check system status
check_status() {
    local arch="✗"
    local live="✗"
    local root="✗"
    local btrfs="✗"
    local snapper="✗"
    local installed="✗"

    [[ -f /etc/os-release ]] && grep -q "ID=arch" /etc/os-release && arch="✓"
    [[ -f /etc/os-release ]] && grep -q "ARCHISO" /etc/os-release && live="✓"
    [[ $EUID -eq 0 ]] && root="✓"
    command -v findmnt >/dev/null && findmnt -n -o FSTYPE / 2>/dev/null | grep -q "btrfs" && btrfs="✓"
    [[ -f /etc/snapper/configs/root ]] && snapper="✓"

    if [[ -f "/arch-setup/.installed" ]]; then
        installed="✓"
    elif [[ -d "/arch-setup" ]]; then
        installed="⚠"
    fi

    echo -e "${BLUE}System Status:${NC}"
    echo -e "  Arch: $arch   Live CD: $live   Root: $root"
    echo -e "  Btrfs: $btrfs   Snapper: $snapper"
    echo -e "  Installed: $installed"
    echo
}

# Download scripts
download_scripts() {
    log "Downloading scripts..."
    for script in "${SCRIPTS[@]}"; do
        echo -n "  $script ... "
        if curl -fsSL -o "${DOWNLOAD_DIR}/${script}" "${SCRIPT_URL}/${script}"; then
            chmod +x "${DOWNLOAD_DIR}/${script}"
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAIL${NC}"
        fi
    done
}

# Run a script
run_script() {
    local script="$1"
    local path="${DOWNLOAD_DIR}/${script}"
    
    if [[ ! -f "$path" ]]; then
        error "Script $script not downloaded!"
        return 1
    fi
    
    # Check if script needs root
    local needs_root=false
    case "$script" in
        "archInstall.sh"|"setupAfterInstall.sh"|"installDE.sh")
            needs_root=true
            ;;
    esac
    
    echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Running: ${YELLOW}$script${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"
    
    # If root is needed, run with sudo (or directly if already root)
    if [[ "$needs_root" == true ]]; then
        if [[ $EUID -eq 0 ]]; then
            "$path"
        else
            if command -v sudo >/dev/null 2>&1; then
                echo -e "${YELLOW}This script requires root privileges.${NC}"
                echo -e "${CYAN}Running with sudo (enter your password)...${NC}"
                echo
                sudo "$path"
            else
                error "sudo is not installed!"
                return 1
            fi
        fi
    else
        # installApps.sh - run as current user
        "$path"
    fi
    
    local code=$?
    
    if [[ $code -eq 0 ]]; then
        log "$script completed successfully"
    else
        error "$script failed with error ($code)"
    fi
    return $code
}

# Main menu
show_menu() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${YELLOW}Arch Linux Installation Manager${NC}    ${BLUE}║${NC}"
    echo -e "${BLUE}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  1) Install Arch (archInstall.sh)                 ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  2) Setup Snapper/GRUB (setupAfterInstall)        ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  3) Install DE (installDE.sh)                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  4) Install applications (installApps.sh)         ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  5) INSTALL ALL (2→3→4)                           ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  6) Download scripts                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  0) Exit                                          ${BLUE}║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
}

# Prerequisites check
check_prereq() {
    local script="$1"
    case "$script" in
        "archInstall.sh")
            [[ $EUID -ne 0 ]] && { error "Need root!"; return 1; }
            [[ ! -d /sys/firmware/efi ]] && { error "Not UEFI!"; return 1; }
            ;;
        "setupAfterInstall.sh")
            [[ $EUID -ne 0 ]] && { error "Need root!"; return 1; }
            [[ ! -f /etc/os-release ]] || ! grep -q "ID=arch" /etc/os-release && { error "Not Arch!"; return 1; }
            ;;
        "installDE.sh")
            [[ ! -f /etc/os-release ]] || ! grep -q "ID=arch" /etc/os-release && { error "Not Arch!"; return 1; }
            ;;
        "installApps.sh")
            [[ $EUID -eq 0 ]] && { error "Cannot run as root!"; return 1; }
            [[ ! -f /etc/os-release ]] || ! grep -q "ID=arch" /etc/os-release && { error "Not Arch!"; return 1; }
            command -v sudo >/dev/null || { error "sudo missing!"; return 1; }
            ;;
    esac
    return 0
}

# Install all (Live CD only)
install_all() {
    log "Starting full installation..."
    local failed=0
    
    for script in "${SCRIPTS[@]}"; do
        echo -e "\n${BLUE}>>> $script${NC}"
        if check_prereq "$script"; then
            run_script "$script" || failed=$((failed+1))
        else
            warn "Skipping $script (prerequisites not met)"
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        log "All installed successfully! 🎉"
    else
        warn "$failed scripts failed"
    fi
}

# Install remaining scripts (after reboot)
install_remaining() {
    log "Arch is already installed – running remaining scripts..."
    local failed=0
    local scripts_to_run=(
        "setupAfterInstall.sh"
        "installDE.sh"
        "installApps.sh"
    )

    for script in "${scripts_to_run[@]}"; do
        echo -e "\n${BLUE}>>> $script${NC}"
        if check_prereq "$script"; then
            run_script "$script" || failed=$((failed+1))
        else
            warn "Skipping $script (prerequisites not met)"
        fi
    done

    if [[ $failed -eq 0 ]]; then
        log "All remaining scripts completed successfully! 🎉"
        touch "/arch-setup/.installed"
    else
        warn "$failed scripts failed"
    fi
}

# ---------------- MAIN PROGRAM ----------------
main() {
    # Download scripts only if not present (Live CD)
    local need_download=false
    for script in "${SCRIPTS[@]}"; do
        [[ ! -f "${DOWNLOAD_DIR}/${script}" ]] && need_download=true
    done
    
    if [[ "$need_download" == true ]]; then
        log "Scripts not found. Downloading..."
        download_scripts
        echo
    fi
    
    while true; do
        check_status
        show_menu
        read -r -p "Choice [0-6]: " choice
        
        case "$choice" in
            1|2|3|4)
                script="${SCRIPTS[$((choice-1))]}"
                echo
                if check_prereq "$script"; then
                    run_script "$script"
                fi
                echo
                read -r -p "Press Enter..."
                ;;
            5)
                if [[ -f "/arch-setup/.installed" ]]; then
                    error "Setup is already complete!"
                else
                    install_remaining
                fi
                echo
                read -r -p "Press Enter..."
                ;;
            6)
                download_scripts
                echo
                read -r -p "Press Enter..."
                ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                error "Unknown option"
                echo
                read -r -p "Press Enter..."
                ;;
        esac
    done
}

# Handle command line arguments
if [[ $# -gt 0 ]]; then
    case "$1" in
        --download) download_scripts; exit 0 ;;
        --install) download_scripts; install_all; exit 0 ;;
        --help) echo "Usage: $0 [--download|--install|--help]"; exit 0 ;;
        *)
            if [[ -f "${DOWNLOAD_DIR}/$1" ]]; then
                run_script "$1" "${@:2}"
                exit $?
            else
                error "Unknown option: $1"
                exit 1
            fi
            ;;
    esac
fi

main "$@"
