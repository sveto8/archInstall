#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Arch Linux Installation Manager
# ============================================================

# URL baza za skripte (promijeni prema svom repozitoriju)
SCRIPT_URL="https://raw.githubusercontent.com/sveto8/archInstall/main"

# Liste skripti
SCRIPTS=(
    "archInstall.sh"
    "setupAfterInstall.sh"
    "installDE.sh"
    "installApps.sh"
)

WORK_DIR="${HOME}/arch-setup"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
mkdir -p "$DOWNLOAD_DIR"

# ---------------- BOJE ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------- FUNKCIJE ----------------
log() { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}   $*${NC}"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Provjera statusa sustava
check_status() {
    local arch="✗"
    local live="✗"
    local root="✗"
    local btrfs="✗"
    local snapper="✗"
    
    [[ -f /etc/os-release ]] && grep -q "ID=arch" /etc/os-release && arch="✓"
    [[ -f /etc/os-release ]] && grep -q "ARCHISO" /etc/os-release && live="✓"
    [[ $EUID -eq 0 ]] && root="✓"
    command -v findmnt >/dev/null && findmnt -n -o FSTYPE / 2>/dev/null | grep -q "btrfs" && btrfs="✓"
    [[ -f /etc/snapper/configs/root ]] && snapper="✓"
    
    echo -e "${BLUE}Status sustava:${NC}"
    echo -e "  Arch: $arch   Live CD: $live   Root: $root"
    echo -e "  Btrfs: $btrfs   Snapper: $snapper"
    echo
}

# Preuzimanje skripti
download_scripts() {
    log "Preuzimanje skripti..."
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

# Pokretanje skripte
run_script() {
    local script="$1"
    local path="${DOWNLOAD_DIR}/${script}"
    
    if [[ ! -f "$path" ]]; then
        error "Skripta $script nije preuzeta!"
        return 1
    fi
    
    echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Pokrećem: ${YELLOW}$script${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"
    
    "$path"
    local code=$?
    
    if [[ $code -eq 0 ]]; then
        log "$script završena uspješno"
    else
        error "$script završila s greškom ($code)"
    fi
    return $code
}

# Glavni izbornik
show_menu() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${YELLOW}Arch Linux Installation Manager${NC}              ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  1) Instaliraj Arch (archInstall.sh)           ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  2) Postavi Snapper/GRUB (setupAfterInstall)  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  3) Instaliraj DE (installDE.sh)              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  4) Instaliraj aplikacije (installApps.sh)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  5) INSTALIRAJ SVE (1→2→3→4)                 ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  6) Preuzmi skripte                           ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  0) Izlaz                                    ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
}

# Provjera preduvjeta
check_prereq() {
    local script="$1"
    case "$script" in
        "archInstall.sh")
            [[ $EUID -ne 0 ]] && { error "Treba root!"; return 1; }
            [[ ! -d /sys/firmware/efi ]] && { error "Nije UEFI!"; return 1; }
            ;;
        "setupAfterInstall.sh")
            [[ $EUID -ne 0 ]] && { error "Treba root!"; return 1; }
            [[ ! -f /etc/os-release ]] || ! grep -q "ID=arch" /etc/os-release && { error "Nije Arch!"; return 1; }
            ;;
        "installDE.sh")
            [[ ! -f /etc/os-release ]] || ! grep -q "ID=arch" /etc/os-release && { error "Nije Arch!"; return 1; }
            ;;
        "installApps.sh")
            [[ $EUID -eq 0 ]] && { error "Ne smije se pokrenuti kao root!"; return 1; }
            [[ ! -f /etc/os-release ]] || ! grep -q "ID=arch" /etc/os-release && { error "Nije Arch!"; return 1; }
            command -v sudo >/dev/null || { error "sudo nedostaje!"; return 1; }
            ;;
    esac
    return 0
}

# Instalacija svega
install_all() {
    log "Pokrećem potpunu instalaciju..."
    local failed=0
    
    for script in "${SCRIPTS[@]}"; do
        echo -e "\n${BLUE}>>> $script${NC}"
        if check_prereq "$script"; then
            run_script "$script" || failed=$((failed+1))
        else
            warn "Preskačem $script (preduvjeti nisu zadovoljeni)"
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        log "Sve uspješno instalirano! 🎉"
    else
        warn "$failed skripti nije uspjelo"
    fi
}

# ---------------- GLAVNI PROGRAM ----------------
main() {
    # Prvo preuzmi skripte ako nisu dostupne
    local need_download=false
    for script in "${SCRIPTS[@]}"; do
        [[ ! -f "${DOWNLOAD_DIR}/${script}" ]] && need_download=true
    done
    
    if [[ "$need_download" == true ]]; then
        log "Skripte nisu preuzete. Preuzimam..."
        download_scripts
        echo
    fi
    
    while true; do
        check_status
        show_menu
        read -r -p "Odabir [0-6]: " choice
        
        case "$choice" in
            1|2|3|4)
                script="${SCRIPTS[$((choice-1))]}"
                echo
                if check_prereq "$script"; then
                    run_script "$script"
                fi
                echo
                read -r -p "Pritisnite Enter..."
                ;;
            5)
                install_all
                echo
                read -r -p "Pritisnite Enter..."
                ;;
            6)
                download_scripts
                echo
                read -r -p "Pritisnite Enter..."
                ;;
            0)
                echo -e "${GREEN}Doviđenja!${NC}"
                exit 0
                ;;
            *)
                error "Nepoznata opcija"
                echo
                read -r -p "Pritisnite Enter..."
                ;;
        esac
    done
}

# Ako je pokrenut s argumentom
if [[ $# -gt 0 ]]; then
    case "$1" in
        --download) download_scripts; exit 0 ;;
        --install) download_scripts; install_all; exit 0 ;;
        --help) echo "Koristi: $0 [--download|--install|--help]"; exit 0 ;;
        *)
            # Pokušaj pokrenuti zadanu skriptu
            if [[ -f "${DOWNLOAD_DIR}/$1" ]]; then
                run_script "$1" "${@:2}"
                exit $?
            else
                error "Nepoznata opcija: $1"
                exit 1
            fi
            ;;
    esac
fi

main "$@"
